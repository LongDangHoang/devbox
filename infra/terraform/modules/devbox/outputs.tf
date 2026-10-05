output "instance_id" {
  value = aws_instance.this.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
