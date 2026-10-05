locals {
  name = split("/", var.repo)[1]
}

# Fails if the repo does not exist (desired).
data "github_repository" "this" {
  name = local.name
}

data "github_user" "me" {
  username = var.reviewer_username
}

resource "github_repository_environment" "modal" {
  repository  = local.name
  environment = "modal"

  reviewers {
    users = [data.github_user.me.id]
  }

  # protected default branch => only the default branch can deploy
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_actions_environment_secret" "modal" {
  for_each = toset(["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET", "WANDB_API_KEY"])

  repository  = local.name
  environment = github_repository_environment.modal.environment
  secret_name = each.value
  value       = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "github_branch_protection" "default" {
  repository_id = data.github_repository.this.node_id
  pattern       = data.github_repository.this.default_branch

  allows_force_pushes = false
  allows_deletions    = false
  # Agent PAT acts as the owner, so admins must be enforced or the rules don't bind it.
  enforce_admins = true

  required_pull_request_reviews {
    required_approving_review_count = 0
  }
}
