# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "this" {
  for_each = var.instances

  ami                         = data.aws_ami.al2023.id
  instance_type               = each.value.instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = var.subnet_ids[each.value.subnet_name]
  vpc_security_group_ids      = [for name in each.value.security_group_ids : var.security_group_ids[name]]
  associate_public_ip_address = each.value.associate_public_ip

  # No user_data: ship as a clean Amazon Linux 2023 instance for MW verification.

  tags = { Name = "${var.name_prefix}-${each.key}" }
}
