# ===== Common =====
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

# ===== Network =====
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

# AZs are auto-detected in network module by default.
variable "availability_zones" {
  description = "Explicit AZ list. Empty means auto-detect first 2 AZs in the region."
  type        = list(string)
  default     = []
}

# ===== EC2 / KeyPair =====
variable "key_pair_name" {
  type = string
}

# ===== Security Groups =====
# common SG always created (SSH only). CIDR is configurable.
variable "common_ssh_cidr" {
  description = "CIDR allowed to SSH(22) on common SG"
  type        = string
  default     = ""
}

# Additional SGs (optional). Each SG can have multiple ingress rules.
# egress is implicitly 0.0.0.0/0 on all SGs.
variable "security_groups" {
  description = "Map of additional security groups keyed by SG name"
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

# ===== EC2 instances =====
# Keyed by server name. Empty map means no EC2 will be created.
variable "instances" {
  description = "Map of EC2 instances keyed by server name"
  type = map(object({
    instance_type      = string
    subnet_name        = string         # subnet name from network module outputs (e.g. "public-a", "private-c")
    security_group_ids = list(string)   # SG names (e.g. ["common", "web"])
    associate_public_ip = optional(bool, false)
  }))
  default = {}
}

# ===== Feature toggles =====
variable "enable_nat" {
  description = "Create NAT Gateway"
  type        = bool
  default     = false
}

variable "enable_alb" {
  description = "Create ALB"
  type        = bool
  default     = false
}

variable "alb_target_instances" {
  description = "Instance names (from var.instances keys) to attach to ALB target group"
  type        = list(string)
  default     = []
}

variable "alb_allowed_cidr" {
  description = "CIDR allowed to access ALB on HTTP(80)"
  type        = string
  default     = "0.0.0.0/0"
}
