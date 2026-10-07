variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
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

# Machine-user account the boxes push as (its token goes onto the box via `devbox secrets`).
variable "agent_github_username" {
  type = string
}

variable "budget_email" {
  type = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 30
}
