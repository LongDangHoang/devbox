terraform {
  required_version = ">= 1.6"

  # Partial config: terraform init -backend-config="bucket=..." -backend-config="key=devbox/terraform.tfstate" -backend-config="region=..."
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

# Admin token comes from the GITHUB_TOKEN env var on the machine running terraform; never placed on a box.
provider "github" {
  owner = var.github_owner
}
