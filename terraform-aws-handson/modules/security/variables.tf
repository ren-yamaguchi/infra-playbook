variable "name_prefix" { type = string }
variable "vpc_id" { type = string }

variable "common_ssh_cidr" {
  description = "CIDR allowed to SSH(22) on the common SG. Empty disables SSH ingress."
  type        = string
  default     = ""
}

variable "security_groups" {
  description = "Additional SGs to create. Keyed by SG name."
  type = map(object({
    description = string
    ingress_rules = list(object({
      description = string
      from_port   = number
      to_port     = number
      protocol    = string
      cidr_blocks = list(string)
    }))
  }))
  default = {}
}
