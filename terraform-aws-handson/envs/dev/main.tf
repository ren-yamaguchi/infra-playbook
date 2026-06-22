locals {
  name_prefix = "${var.project_name}-${var.environment}"

  ec2_subnet_ids = var.ec2_subnet_type == "public" ? module.network.public_subnet_ids : module.network.private_subnet_ids
}

# ===== network (always) =====
module "network" {
  source = "../../modules/network"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
}

# ===== NAT (optional) =====
module "nat" {
  source = "../../modules/nat"
  count  = var.enable_nat ? 1 : 0

  name_prefix            = local.name_prefix
  public_subnet_id       = module.network.public_subnet_ids[0]
  private_route_table_id = module.network.private_route_table_id
}

# ===== EC2 =====
module "compute" {
  source = "../../modules/compute"

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = local.ec2_subnet_ids
  associate_public_ip = var.ec2_subnet_type == "public"
  instance_type       = var.instance_type
  instance_count      = var.instance_count
  key_pair_name       = var.key_pair_name
  allowed_ssh_cidr    = var.allowed_ssh_cidr
}

# ===== ALB (optional) =====
module "alb" {
  source = "../../modules/alb"
  count  = var.enable_alb ? 1 : 0

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  target_instance_ids = module.compute.instance_ids
  allowed_cidr        = var.alb_allowed_cidr
}
