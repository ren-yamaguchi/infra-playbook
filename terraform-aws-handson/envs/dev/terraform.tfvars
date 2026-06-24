project_name    = "handson"
environment     = "dev"

# Your EC2 key pair name (created in target region)
key_pair_name   = "your-key-name"

# CIDR allowed to SSH(22) on the common SG.
# Replace x.x.x.x/32 with your global IP (curl https://checkip.amazonaws.com)
common_ssh_cidr = "x.x.x.x/32"

# ===== Additional Security Groups (optional) =====
# Define any number of SGs. Each SG can have multiple ingress rules.
# Each EC2 instance can be attached to one or more SGs by name.
security_groups = {
  # Example: Web tier (HTTP / HTTPS open to internet)
  # "web" = {
  #   description = "Web tier"
  #   ingress_rules = [
  #     { description = "HTTP",  from_port = 80,  to_port = 80,  protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] },
  #     { description = "HTTPS", from_port = 443, to_port = 443, protocol = "tcp", cidr_blocks = ["0.0.0.0/0"] }
  #   ]
  # }

  # Example: DB tier (PostgreSQL from VPC only)
  # "db" = {
  #   description = "DB tier"
  #   ingress_rules = [
  #     { description = "PostgreSQL from VPC", from_port = 5432, to_port = 5432, protocol = "tcp", cidr_blocks = ["10.0.0.0/16"] }
  #   ]
  # }
}

# ===== EC2 instances (map keyed by server name) =====
# Empty {} means no EC2 will be created.
# subnet_name: "public-a", "public-c", "private-a", "private-c" etc.
#              (see network module outputs)
# security_group_ids: list of SG names. "common" is always available.
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

# alb_target_instances = ["server-01"]   # required when enable_alb = true
