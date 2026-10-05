output "projects" {
  value = {
    for k, m in module.devbox : k => {
      instance_id    = m.instance_id
      data_volume_id = m.data_volume_id
      repo           = local.projects[k].repo
    }
  }
}

output "instance_ids" {
  value = { for k, m in module.devbox : k => m.instance_id }
}
