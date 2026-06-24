variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "target_instance_ids" { type = list(string) }

variable "allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}
