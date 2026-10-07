terraform {
  required_version = ">= 1.11"

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
  # The deployer role's guard (infra/bootstrap) only lets it change/delete resources with this tag.
  default_tags {
    tags = { ManagedBy = "devbox" }
  }
}

# Authenticates via GITHUB_TOKEN, which `devbox` sets from your local `gh` login; never placed on a box.
provider "github" {
  owner = var.github_owner
}
