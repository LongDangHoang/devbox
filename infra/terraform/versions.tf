terraform {
  required_version = ">= 1.11" # write-only attributes (value_wo)

  # Partial config: terraform init -backend-config=backend.hcl (see README).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Authenticates via GITHUB_TOKEN, which `devbox` sets from your local `gh` login; never placed on a box.
provider "github" {
  owner = var.github_owner
}
