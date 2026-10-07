data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

locals {
  tags        = { Project = var.name }
  scripts_dir = "${path.module}/../../../scripts"
  # First boot only: install infra/scripts/* to /opt/devbox/scripts and enable setup-boot.service
  # (which runs bootstrap.sh every boot). Later script changes reach boxes via `devbox sync`.
  user_data = base64gzip(templatefile("${path.module}/user_data.sh.tftpl", {
    files = { for f in fileset(local.scripts_dir, "*") : f => chomp(file("${local.scripts_dir}/${f}")) }
  }))
}

resource "aws_security_group" "this" {
  name        = "devbox-${var.name}"
  description = "devbox ${var.name}: ssh from EICE only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.eice_sg_id]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "devbox-${var.name}" })
}

# The shared endpoint SG may reach this box on 22 (rule lives here so it comes and goes with the project).
resource "aws_vpc_security_group_egress_rule" "eice" {
  security_group_id            = var.eice_sg_id
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  tags                         = local.tags
}

# Needs the `Project` cost allocation tag activated once (Billing -> Cost allocation tags).
resource "aws_budgets_budget" "this" {
  name         = "devbox-${var.name}"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", var.name)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}

# Data volume: depends only on AZ/size so instance changes never replace it.
# final_snapshot leaves a snapshot behind (with these tags) when the project is retired.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_gb
  type              = "gp3"
  final_snapshot    = true
  tags              = merge(local.tags, { Name = "devbox-${var.name}-data" })
}

resource "aws_launch_template" "this" {
  name          = "devbox-${var.name}"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  user_data     = local.user_data

  instance_initiated_shutdown_behavior = "stop"
  vpc_security_group_ids               = [aws_security_group.this.id]

  # No instance profile: the box has no AWS identity. IMDS (root-readable tags) holds no credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
  }

  # default_tags don't reach tag_specifications, hence ManagedBy here.
  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "devbox-${var.name}-root", ManagedBy = "devbox" })
  }

  # A new Ubuntu AMI or script edit must not create a new LT version for every project on each apply
  # (that would break `devbox add`/`retire` scoped plans); scripts reach existing boxes via `devbox sync`.
  # To roll a box onto a new AMI/user data: terraform apply -replace=module.devbox["<name>"].aws_launch_template.this
  # (then replace the instance as well; the data volume survives).
  lifecycle {
    ignore_changes = [image_id, user_data]
    precondition {
      condition     = length(local.user_data) <= 21848 # base64 of 16384 bytes, the EC2 user data limit
      error_message = "Gzipped user data exceeds 16 KB; shrink infra/scripts."
    }
  }
}

resource "aws_instance" "this" {
  subnet_id = var.subnet_id

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # Read by bootstrap.sh from IMDS (instance_metadata_tags). Set here rather than in the LT so changes
  # update the running instance in place (the instance ignores LT changes, see below).
  tags = merge(local.tags, {
    Name         = "devbox-${var.name}"
    Repo         = var.repo
    IdleMinutes  = tostring(var.idle_minutes)
    DataVolumeId = aws_ebs_volume.data.id
  })

  # LT version bumps (instance type, SG, ...) would otherwise replace the box. Apply such
  # changes deliberately with: terraform apply -replace=module.devbox["<name>"].aws_instance.this
  lifecycle {
    ignore_changes = [launch_template]
  }
}

resource "aws_volume_attachment" "data" {
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data.id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}
