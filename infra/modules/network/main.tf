data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Zone names differ per region, so they are looked up, never typed.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # One number per zone: 0, 1, 2. Used to carve subnet ranges.
  az_index = { for i, az in local.azs : az => i }

  nat_azs = var.enable_nat ? (var.single_nat ? [local.azs[0]] : local.azs) : []
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name}-vpc" })
}

# ---------- subnets: three tiers, one of each per zone ----------

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.cidr, 8, each.value)
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${each.key}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "app" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr, 8, each.value + 10)

  tags = merge(var.tags, { Name = "${var.name}-app-${each.key}", Tier = "app" })
}

resource "aws_subnet" "data" {
  for_each = local.az_index

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.cidr, 8, each.value + 20)

  tags = merge(var.tags, { Name = "${var.name}-data-${each.key}", Tier = "data" })
}

# ---------- public: the internet gateway and its route ----------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-rt-public" })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------- optional NAT for the app tier ----------

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  depends_on    = [aws_internet_gateway.this]

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })
}

resource "aws_route_table" "app" {
  for_each = local.az_index

  vpc_id = aws_vpc.this.id

  # Only add the internet route when NAT exists. With single_nat, every
  # zone points at the one gateway in the first zone.
  dynamic "route" {
    for_each = var.enable_nat ? [1] : []

    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[var.single_nat ? local.azs[0] : each.key].id
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-rt-app-${each.key}" })
}

resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

# ---------- data: no route out at all ----------

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-rt-data" })
}

resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

# ---------- a free, private path to S3 ----------
# Container image layers are stored in S3. Without this, every image pull from
# a private subnet goes through the NAT gateway, which charges per gigabyte.
# A gateway endpoint costs nothing and keeps that traffic inside AWS.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for az in local.azs : aws_route_table.app[az].id]

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}
