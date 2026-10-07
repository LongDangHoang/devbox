# One-time, applied by a human with admin credentials (local state, gitignored; nothing secret in it):
#   terraform -chdir=infra/bootstrap init && terraform -chdir=infra/bootstrap apply -var state_bucket=<bucket>
# Creates the identity `devbox` runs as. The guard is accident prevention, not attacker containment:
# the deployer can't change or delete resources that aren't tagged ManagedBy=devbox.

terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-2"
}

# Terraform state bucket/key of infra/terraform (see backend.hcl); its objects (incl. the
# <key>.tflock lock file) are exempt from the delete guard.
variable "state_bucket" { type = string }

variable "state_key" {
  type    = string
  default = "devbox/terraform.tfstate"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  # Negated operators also match when the tag is absent: untagged resources are protected too.
  not_devbox = { StringNotEquals = { "aws:ResourceTag/ManagedBy" = "devbox" } }
}

# Long-lived access key lives only in ~/.aws/credentials; all it can do is assume the role (with MFA).
resource "aws_iam_user" "operator" {
  name = "devbox-operator"
}

resource "aws_iam_user_policy" "operator" {
  name = "assume-devbox-deployer"
  user = aws_iam_user.operator.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.deployer.arn
    }]
  })
}

resource "aws_iam_role" "deployer" {
  name                 = "devbox-deployer"
  max_session_duration = 14400 # 4h, so a long apply doesn't outlive its credentials
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = aws_iam_user.operator.arn }
      Condition = { Bool = { "aws:MultiFactorAuthPresent" = "true" } }
    }]
  })
}

# Everything except iam/organizations/account (it does allow iam:CreateServiceLinkedRole, which the
# EC2 Instance Connect Endpoint needs on first create). So the role can't edit its own guard.
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.deployer.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "guard" {
  name = "devbox-guard"
  role = aws_iam_role.deployer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Ec2OnlyDevboxTagged"
        Effect = "Deny"
        Action = [
          "ec2:Terminate*", "ec2:Delete*", "ec2:Detach*", "ec2:Disassociate*", "ec2:Modify*",
          "ec2:Revoke*", "ec2:Authorize*", "ec2:Replace*", "ec2:Stop*", "ec2:Reboot*",
        ]
        # Authorize* also authorizes the new (not yet tagged) security-group-rule; the SG itself is checked.
        NotResource = ["arn:aws:ec2:*:*:security-group-rule/*"]
        Condition   = local.not_devbox
      },
      {
        Sid    = "DeletesOnlyDevboxTagged"
        Effect = "Deny"
        Action = [
          "s3:Delete*", "dynamodb:Delete*", "rds:Delete*", "lambda:Delete*", "logs:Delete*",
          "ecr:Delete*", "ecs:Delete*", "eks:Delete*", "elasticloadbalancing:Delete*",
          "elasticfilesystem:Delete*", "cloudformation:Delete*", "route53:Delete*",
          "secretsmanager:Delete*", "sns:Delete*", "sqs:Delete*", "backup:Delete*",
          "cloudtrail:Delete*", "cloudtrail:StopLogging", "kms:ScheduleKeyDeletion", "kms:DisableKey",
        ]
        NotResource = ["arn:aws:s3:::${var.state_bucket}/${var.state_key}*"]
        Condition   = local.not_devbox
      },
      {
        # budgets:ModifyBudget covers create/update/delete; new budgets have no tag yet, so match by name.
        Sid         = "BudgetsOnlyDevbox"
        Effect      = "Deny"
        Action      = "budgets:ModifyBudget"
        NotResource = ["arn:aws:budgets::${local.account}:budget/devbox-*"]
      },
      {
        Sid      = "KeepServiceLinkedRoles"
        Effect   = "Deny"
        Action   = "iam:DeleteServiceLinkedRole"
        Resource = "*"
      },
    ]
  })
}

output "operator_user" {
  value = aws_iam_user.operator.name
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}
