variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "associate_public_ip" { type = bool }
variable "instance_type" { type = string }
variable "instance_count" { type = number }
variable "key_pair_name" { type = string }

variable "allowed_ssh_cidr" {
  type    = string
  default = ""
}
