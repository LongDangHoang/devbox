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

# Machine-user account the boxes push as (its token goes in SSM via `devbox secrets`).
variable "agent_github_username" {
  type = string
}

# Public egress IPs of the boxes (e.g. NAT gateway EIP as "x.x.x.x/32"). When set, the box role's
# credentials only work from these IPs. Leave empty if boxes use changing public IPs.
variable "egress_cidrs" {
  type    = list(string)
  default = []
}

variable "budget_email" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 30
}
