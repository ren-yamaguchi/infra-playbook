variable "name_prefix" { type = string }
variable "key_pair_name" { type = string }

# Instance definitions, keyed by server name.
variable "instances" {
  type = map(object({
    instance_type       = string
    subnet_name         = string         # key in subnet_ids map (e.g. "public-a")
    security_group_ids  = list(string)   # SG names (e.g. ["common", "web"])
    associate_public_ip = optional(bool, false)
  }))
}

# Subnet name -> subnet ID (passed in from network module)
variable "subnet_ids" {
  type = map(string)
}

# SG name -> SG ID (passed in from security module)
variable "security_group_ids" {
  type = map(string)
}
