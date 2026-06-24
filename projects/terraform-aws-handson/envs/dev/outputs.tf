output "vpc_id" {
  value = module.network.vpc_id
}

output "subnet_ids" {
  description = "All subnet IDs (map keyed by subnet name)"
  value       = module.network.subnet_ids
}

output "security_group_ids" {
  description = "All SG IDs (map keyed by SG name)"
  value       = module.security.security_group_ids
}

output "instance_ids" {
  description = "EC2 instance IDs keyed by server name"
  value       = module.compute.instance_ids
}

output "public_ips" {
  description = "EC2 public IPs keyed by server name (empty if not public)"
  value       = module.compute.public_ips
}

output "private_ips" {
  description = "EC2 private IPs keyed by server name"
  value       = module.compute.private_ips
}

output "ssh_commands" {
  description = "SSH command examples keyed by server name (only for public instances)"
  value       = module.compute.ssh_commands
}

output "alb_dns_name" {
  value = var.enable_alb ? module.alb[0].dns_name : null
}
