project_name     = "handson"
environment      = "dev"

key_pair_name    = "my-keypair-name"   # your key pair name
allowed_ssh_cidr = "x.x.x.x/32"   # your global IP/32
instance_count   = 1

# Pattern 1: minimal
ec2_subnet_type = "public"
enable_nat      = false
enable_alb      = false

# Pattern 2: with ALB (EC2 still public)
# ec2_subnet_type = "public"
# enable_nat      = false
# enable_alb      = true

# Pattern 3: production-like (EC2 in private, NAT + ALB)
# ec2_subnet_type = "private"
# enable_nat      = true
# enable_alb      = true

