output "vpc_id" { value = aws_vpc.this.id }

# All subnet IDs keyed by subnet name
output "subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id }
}

# Public subnet IDs only (useful for ALB which requires multiple public subnets)
output "public_subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id if var.subnets[k].type == "public" }
}

# Private subnet IDs only
output "private_subnet_ids" {
  value = { for k, s in aws_subnet.this : k => s.id if var.subnets[k].type == "private" }
}

output "private_route_table_id" { value = aws_route_table.private.id }