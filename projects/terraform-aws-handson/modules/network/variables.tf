variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }

# Subnet definitions, keyed by subnet name.
# type must be "public" or "private".
variable "subnets" {
  description = "Map of subnets keyed by name. Each must specify cidr, az, type."
  type = map(object({
    cidr = string
    az   = string
    type = string
  }))

  validation {
    condition     = alltrue([for s in var.subnets : contains(["public", "private"], s.type)])
    error_message = "Each subnet's type must be 'public' or 'private'."
  }
}