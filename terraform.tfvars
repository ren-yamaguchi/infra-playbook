project_name     = "handson"
environment      = "dev"

key_pair_name    = "aws-cli-tf"
allowed_ssh_cidr = "175.41.114.205/32"
instance_count   = 2

# Pattern 1: minimal (current)
ec2_subnet_type = "public"
enable_nat      = false
enable_alb      = false
