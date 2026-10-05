variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "scripts_bucket" {
  type = string
}

variable "scripts_prefix" {
  type    = string
  default = "devbox/scripts"
}

variable "default_instance_type" {
  type    = string
  default = "m7g.xlarge"
}

variable "default_data_gb" {
  type    = number
  default = 50
}

variable "idle_minutes" {
  type    = number
  default = 30
}

variable "github_owner" {
  type = string
}

variable "github_reviewer_username" {
  type = string
}

# Machine-user account the boxes push as (its token goes in SSM via `make secrets`).
variable "agent_github_username" {
  type = string
}
