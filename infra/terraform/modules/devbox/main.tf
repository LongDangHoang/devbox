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

data "aws_caller_identity" "current" {}

locals {
  tags      = { Project = var.name }
  param_arn = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/devbox/${var.name}"
}

resource "aws_security_group" "this" {
  name        = "devbox-${var.name}"
  description = "devbox ${var.name}: no ingress"
  vpc_id      = var.vpc_id

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

resource "aws_iam_role" "this" {
  name = "devbox-${var.name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "this" {
  name = "devbox-${var.name}"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [local.param_arn, "${local.param_arn}/*"]
      },
      # AmazonSSMManagedInstanceCore allows ssm:GetParameter(s) on "*"; this caps reads at our own path.
      # SecureString decrypt needs no IAM grant: the AWS-managed aws/ssm key policy already allows
      # kms:Decrypt for account principals via SSM.
      {
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        NotResource = [local.param_arn, "${local.param_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:aws:s3:::${var.scripts_bucket}/${var.scripts_prefix}/*"
      },
      {
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = "arn:aws:s3:::${var.scripts_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["${var.scripts_prefix}/*", var.scripts_prefix] } }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "devbox-${var.name}"
  role = aws_iam_role.this.name
}

# Write-only: the value never enters state, and later applies don't diff it, so
# `make secrets` (put-parameter --overwrite) sticks. Bumping value_wo_version resets it to CHANGE_ME.
resource "aws_ssm_parameter" "github_token" {
  name             = "/devbox/${var.name}/github_token"
  type             = "SecureString"
  value_wo         = "CHANGE_ME"
  value_wo_version = 1
}

resource "aws_ssm_parameter" "repo_url" {
  name  = "/devbox/${var.name}/repo_url"
  type  = "String"
  value = "https://github.com/${var.repo}.git"
}

# Bootstrap mounts exactly this volume (by NVMe serial), never "some unformatted disk".
resource "aws_ssm_parameter" "data_volume_id" {
  name  = "/devbox/${var.name}/data_volume_id"
  type  = "String"
  value = aws_ebs_volume.data.id
}

resource "aws_ssm_parameter" "idle_minutes" {
  name  = "/devbox/${var.name}/idle_minutes"
  type  = "String"
  value = tostring(var.idle_minutes)
}

# Data volume: depends only on AZ/size so instance changes never replace it.
# final_snapshot leaves a snapshot behind when the project is retired.
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
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    bucket = var.scripts_bucket
    prefix = var.scripts_prefix
    region = var.region
  }))

  instance_initiated_shutdown_behavior = "stop"
  vpc_security_group_ids               = [aws_security_group.this.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

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

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "devbox-${var.name}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = "devbox-${var.name}-root" })
  }

  # A new Ubuntu AMI must not create a new LT version for every project on each apply.
  # To roll a box onto a new AMI: terraform apply -replace=module.devbox["<name>"].aws_launch_template.this
  # (then replace the instance as well; the data volume survives).
  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "aws_instance" "this" {
  subnet_id = var.subnet_id

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

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
