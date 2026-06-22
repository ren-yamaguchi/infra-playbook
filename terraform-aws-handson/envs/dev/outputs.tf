output "vpc_id" {
  value = module.network.vpc_id
}

output "ec2_subnet_type" {
  value = var.ec2_subnet_type
}

output "ec2_public_ips" {
  description = "Public IPs (valid when EC2 is in public subnet)"
  value       = module.compute.public_ips
}

output "ec2_private_ips" {
  value = module.compute.private_ips
}

output "alb_dns_name" {
  value = var.enable_alb ? module.alb[0].dns_name : null
}

output "ssh_commands" {
  description = "SSH command examples (shown only when EC2 is public)"
  value       = var.ec2_subnet_type == "public" ? module.compute.ssh_commands : []
}
