locals {
  projects = {
    for f in fileset("${path.module}/../projects", "*.json") :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/../projects/${f}"))
  }
}

resource "aws_s3_object" "scripts" {
  for_each = fileset("${path.module}/../scripts", "*")

  bucket = var.scripts_bucket
  key    = "${var.scripts_prefix}/${each.value}"
  source = "${path.module}/../scripts/${each.value}"
  etag   = filemd5("${path.module}/../scripts/${each.value}")
}

module "devbox" {
  source   = "./modules/devbox"
  for_each = local.projects

  name           = each.key
  repo           = each.value.repo
  instance_type  = try(each.value.instance_type, var.default_instance_type)
  data_gb        = try(each.value.data_gb, var.default_data_gb)
  idle_minutes   = var.idle_minutes
  vpc_id         = var.vpc_id
  subnet_id      = var.subnet_id
  region         = var.region
  scripts_bucket = var.scripts_bucket
  scripts_prefix = var.scripts_prefix
}

module "github_project" {
  source   = "./modules/github_project"
  for_each = local.projects

  repo                  = each.value.repo
  reviewer_username     = var.github_reviewer_username
  agent_github_username = var.agent_github_username
}
