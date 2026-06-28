variable "name_prefix" { type = string }
variable "vpc_id" { type = string }

variable "common_ssh_cidr" {
  description = "CIDR allowed to SSH(22) on the common SG. Empty disables SSH ingress."
  type        = string
  default     = ""
}

# Each ingress rule can specify either cidr_blocks or source_security_groups (or both).
# - cidr_blocks: list of CIDR strings (e.g. ["10.0.0.0/16"])
# - source_security_groups: list of SG names defined in this module (e.g. ["web", "app"])
#   "common" is also referencable. Self-reference (same SG name as the key) is allowed.
variable "security_groups" {
  description = "Additional SGs to create. Keyed by SG name."
  type = map(object({
    description = string
    ingress_rules = list(object({
      description            = string
      from_port              = number
      to_port                = number
      protocol               = string
      cidr_blocks            = optional(list(string), [])
      source_security_groups = optional(list(string), [])
    }))
  }))
  default = {}
}