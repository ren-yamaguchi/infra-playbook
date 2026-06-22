output "instance_ids" { value = aws_instance.this[*].id }
output "public_ips" { value = aws_instance.this[*].public_ip }
output "private_ips" { value = aws_instance.this[*].private_ip }

output "ssh_commands" {
  value = [
    for i in aws_instance.this :
    "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${i.public_ip}"
  ]
}
