locals {
  name_prefix = "${var.project_name}-${var.environment}"
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
  public_subnet_id       = values(module.network.public_subnet_ids)[0]
  private_route_table_id = module.network.private_route_table_id
}

# ===== Security Groups (always; "common" always created) =====
module "security" {
  source = "../../modules/security"

  name_prefix      = local.name_prefix
  vpc_id           = module.network.vpc_id
  common_ssh_cidr  = var.common_ssh_cidr
  security_groups  = var.security_groups
}

# ===== EC2 (for_each based) =====
module "compute" {
  source = "../../modules/compute"

  name_prefix       = local.name_prefix
  key_pair_name     = var.key_pair_name
  instances         = var.instances
  subnet_ids        = module.network.subnet_ids        # map keyed by subnet name
  security_group_ids = module.security.security_group_ids  # map keyed by SG name
}

# ===== ALB (optional) =====
module "alb" {
  source = "../../modules/alb"
  count  = var.enable_alb ? 1 : 0

  name_prefix         = local.name_prefix
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = values(module.network.public_subnet_ids)
  target_instance_ids = [for name in var.alb_target_instances : module.compute.instance_ids[name]]
  allowed_cidr        = var.alb_allowed_cidr
