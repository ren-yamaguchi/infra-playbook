# Common SG: SSH only (always created)
resource "aws_security_group" "common" {
  name        = "${var.name_prefix}-common-sg"
  description = "Common SG: SSH"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.common_ssh_cidr != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.common_ssh_cidr]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-common-sg" }
}

# Map of all SG name -> SG ID (for SG-to-SG reference resolution).
# Includes "common" plus all user-defined SGs (self-reference also supported).
locals {
  all_sg_ids = merge(
    { "common" = aws_security_group.common.id },
    { for k, sg in aws_security_group.extra : k => sg.id },
  )
}

# Additional SGs (for_each map). Each ingress rule may use cidr_blocks or
# source_security_groups (or both).
resource "aws_security_group" "extra" {
  for_each = var.security_groups

  name        = "${var.name_prefix}-${each.key}-sg"
  description = each.value.description
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = each.value.ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol

      # Use null when not specified so Terraform omits the attribute.
      cidr_blocks = length(ingress.value.cidr_blocks) > 0 ? ingress.value.cidr_blocks : null
      security_groups = length(ingress.value.source_security_groups) > 0 ? [
        for n in ingress.value.source_security_groups : local.all_sg_ids[n]
      ] : null
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-${each.key}-sg" }
}