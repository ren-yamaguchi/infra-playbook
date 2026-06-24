# Maps keyed by server name (matches keys of var.instances)
output "instance_ids" {
  value = { for k, i in aws_instance.this : k => i.id }
}

output "public_ips" {
  value = { for k, i in aws_instance.this : k => i.public_ip if i.public_ip != "" }
}

output "private_ips" {
  value = { for k, i in aws_instance.this : k => i.private_ip }
}

output "ssh_commands" {
  value = {
    for k, i in aws_instance.this :
    k => "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${i.public_ip}"
    if i.public_ip != ""
  }
}
