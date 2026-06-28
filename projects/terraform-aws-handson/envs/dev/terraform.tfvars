project_name    = "handson"
environment     = "dev"

key_pair_name   = "your-key-name"      # Replace with your key pair name
common_ssh_cidr = "x.x.x.x/32"         # Replace with your global IP/32 (check via: curl https://checkip.amazonaws.com)

# ===== Subnets =====
# Each subnet is defined as subnet_name => { cidr, az, type }.
# type must be "public" or "private".
# Multiple subnets in the same AZ are allowed.
subnets = {
  "public-a"  = { cidr = "10.0.1.0/24",  az = "ap-northeast-1a", type = "public" }
#  "public-c"  = { cidr = "10.0.2.0/24",  az = "ap-northeast-1c", type = "public" }
#  "private-a" = { cidr = "10.0.11.0/24", az = "ap-northeast-1a", type = "private" }
#  "private-c" = { cidr = "10.0.12.0/24", az = "ap-northeast-1c", type = "private" }
}

# ===== Additional Security Groups (optional) =====
# The "common" SG (SSH only) is created automatically; define additional SGs here.
# Each EC2 references SGs by name in security_group_ids inside instances.
#
# Each ingress rule can specify either cidr_blocks (IP-based) or
# source_security_groups (SG-based), or both. SG names defined in this block
# can be referenced, including "common" and self-reference.
security_groups = {
  # Example: Web tier (HTTP / HTTPS from my IP)
  # "web" = {
  #   description = "Web tier"
  #   ingress_rules = [
  #     { description = "HTTP",  from_port = 80,  to_port = 80,  protocol = "tcp", cidr_blocks = ["x.x.x.x/32"] },
  #     { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["x.x.x.x/32"] }
  #   ]
  # }

  # Example: AP tier (Tomcat from web SG only)
  # "ap" = {
  #   description = "AP tier"
  #   ingress_rules = [
  #     { description = "Tomcat from web SG", from_port = 8080, to_port = 8080, protocol = "tcp", source_security_groups = ["web"] }
  #   ]
  # }

  # Example: DB tier (PostgreSQL from ap SG only)
  # "db" = {
  #   description = "DB tier"
  #   ingress_rules = [
  #     { description = "PostgreSQL from ap SG", from_port = 5432, to_port = 5432, protocol = "tcp", source_security_groups = ["ap"] }
  #   ]
  # }

  # Example: Cluster (self-reference for inter-node communication)
  # "cluster" = {
  #   description = "Cluster node sync"
  #   ingress_rules = [
  #     { description = "Cluster sync", from_port = 7000, to_port = 7000, protocol = "tcp", source_security_groups = ["cluster"] }
  #   ]
  # }
}

# ===== EC2 instances =====
# server_name => { instance_type, subnet_name, security_group_ids, associate_public_ip }
# subnet_name must match a key defined in subnets above.
# security_group_ids: list of SG names. "common" is always available.
# Empty {} means no EC2 is created (useful for pre-provisioning VPC + SG only).
instances = {
  "server-01" = {
    instance_type       = "t3.micro"
    subnet_name         = "public-a"
    security_group_ids  = ["common"]
    associate_public_ip = true
  }
}

# ===== Feature toggles =====
enable_nat = false
enable_alb = false

# alb_target_instances = ["server-01"]    # Required when enable_alb = true