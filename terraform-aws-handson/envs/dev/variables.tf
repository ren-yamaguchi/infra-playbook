# ===== 共通 =====
variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "project_name" {
  type    = string
  default = "handson"
}

variable "environment" {
  type    = string
  default = "dev"
}

# ===== ネットワーク =====
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "Explicit AZ list. Empty means auto-detect first 2 AZs in the region."
  type        = list(string)
  default     = []
}

# ===== EC2 =====
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "instance_count" {
  type    = number
  default = 2
}

variable "key_pair_name" {
  type = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH. Empty means no SSH ingress."
  type        = string
  default     = ""
}

variable "ec2_subnet_type" {
  description = "Where to place EC2: public or private"
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.ec2_subnet_type)
    error_message = "ec2_subnet_type must be 'public' or 'private'."
  }
}

# ===== Feature toggles =====
variable "enable_nat" {
  description = "Create NAT Gateway. Required when ec2_subnet_type=private."
  type        = bool
  default     = false
}

variable "enable_alb" {
  description = "Create ALB"
  type        = bool
  default     = false
}

variable "alb_allowed_cidr" {
  description = "CIDR allowed to access ALB on HTTP(80)"
  type        = string
  default     = "0.0.0.0/0"
}
