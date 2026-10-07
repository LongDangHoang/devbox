locals {
  name = split("/", var.repo)[1]
}

# Fails if the repo does not exist (desired).
data "github_repository" "this" {
  name = local.name
}

resource "github_repository_environment" "modal" {
  repository  = local.name
  environment = "modal"

  # No required reviewers: on private repos they need GitHub Enterprise. The gate is the reusable
  # workflow's job-level `if` (only the repo owner can trigger it) plus this branch policy.
  # Only protected branches (i.e. the default branch) can deploy.
  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }
}

resource "github_actions_environment_secret" "modal" {
  for_each = toset(["MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"])

  repository  = local.name
  environment = github_repository_environment.modal.environment
  secret_name = each.value
  value       = "CHANGE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}

# The agent pushes as this machine user, never as the owner, so branch protection binds it.
# The machine user must accept the invitation (github.com/notifications or the email) before
# its token can push; until then the box's clone/push fails.
resource "github_repository_collaborator" "agent" {
  repository = local.name
  username   = var.agent_github_username
  permission = "push"
}

resource "github_branch_protection" "default" {
  repository_id = data.github_repository.this.node_id
  pattern       = data.github_repository.this.default_branch

  allows_force_pushes = false
  allows_deletions    = false
  # Admins (you) may bypass; the agent is a push-only collaborator, so the rules bind it.
  enforce_admins = false

  # The agent can't approve its own PR, and a push after approval needs a fresh approval.
  # (restrict_pushes is org-only; on personal repos the review requirement is the gate.)
  required_pull_request_reviews {
    required_approving_review_count = 1
    require_last_push_approval      = true
    dismiss_stale_reviews           = true
  }
}
