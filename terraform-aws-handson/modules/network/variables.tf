variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }

variable "availability_zones" {
  description = "Explicit AZ list. Empty means auto-detect first 2 AZs in the region."
  type        = list(string)
  default     = []
}
