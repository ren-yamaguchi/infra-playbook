locals {
  # Split subnets by type for route table associations
  public_subnet_names  = [for k, s in var.subnets : k if s.type == "public"]
  private_subnet_names = [for k, s in var.subnets : k if s.type == "private"]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# All subnets created via for_each so any name/AZ/type is allowed
resource "aws_subnet" "this" {
  for_each = var.subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.type == "public"

  tags = { Name = "${var.name_prefix}-${each.key}" }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

# Associate public route table with all public subnets
resource "aws_route_table_association" "public" {
  for_each = toset(local.public_subnet_names)

  subnet_id      = aws_subnet.this[each.value].id
  route_table_id = aws_route_table.public.id
}

# Private Route Table (NAT route is added by nat module)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-private-rt" }
}

# Associate private route table with all private subnets
resource "aws_route_table_association" "private" {
  for_each = toset(local.private_subnet_names)

  subnet_id      = aws_subnet.this[each.value].id
  route_table_id = aws_route_table.private.id
}