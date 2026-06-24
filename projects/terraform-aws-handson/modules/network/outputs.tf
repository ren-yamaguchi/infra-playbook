output "vpc_id" { value = aws_vpc.this.id }

# Subnet IDs as a flat map keyed by "<type>-<az_suffix>" (e.g. "public-a", "private-c").
# This lets EC2 instances reference subnets by name.
output "subnet_ids" {
  value = merge(
    { for i, s in aws_subnet.public : "public-${substr(s.availability_zone, length(s.availability_zone) - 1, 1)}" => s.id },
    { for i, s in aws_subnet.private : "private-${substr(s.availability_zone, length(s.availability_zone) - 1, 1)}" => s.id },
  )
}

# Convenience: keyed maps for public/private only
output "public_subnet_ids" {
  value = { for s in aws_subnet.public : "public-${substr(s.availability_zone, length(s.availability_zone) - 1, 1)}" => s.id }
}

output "private_subnet_ids" {
  value = { for s in aws_subnet.private : "private-${substr(s.availability_zone, length(s.availability_zone) - 1, 1)}" => s.id }
}

output "private_route_table_id" { value = aws_route_table.private.id }
