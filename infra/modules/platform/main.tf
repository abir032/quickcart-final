locals {
  # A short code for the region keeps names under AWS's length limits
  # and makes the region visible in every name.
  region_codes = {
    "us-east-1"      = "use1"
    "us-east-2"      = "use2"
    "us-west-2"      = "usw2"
    "eu-west-1"      = "euw1"
    "eu-central-1"   = "euc1"
    "ap-south-1"     = "aps1"
    "ap-southeast-1" = "apse1"
  }
  region_code = lookup(local.region_codes, var.region, replace(var.region, "-", ""))

  name = "${var.project}-${var.environment}-${local.region_code}"

  tags = {
    Project     = "quickcart"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # With NAT, tasks run in private app subnets. Without it, they need public
  # subnets and a public IP to reach ECR. The security group still only lets
  # the load balancer in either way.
  task_subnet_ids  = var.enable_nat ? module.network.app_subnet_ids : module.network.public_subnet_ids
  assign_public_ip = !var.enable_nat
}

# ---------- the network and who may talk to whom ----------

module "network" {
  source = "../network"

  name       = local.name
  cidr       = var.vpc_cidr
  enable_nat = var.enable_nat
  single_nat = var.single_nat
  tags       = local.tags
}

module "security_groups" {
  source = "../security-groups"

  name     = local.name
  vpc_id   = module.network.vpc_id
  vpc_cidr = var.vpc_cidr
  tags     = local.tags
}

# ---------- a trusted certificate and a real name ----------

module "certificate" {
  source = "../certificate"

  domain_name = var.domain_name
  zone_id     = var.zone_id
  tags        = local.tags
}

module "compute" {
  source = "../compute"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security_groups.alb_id
  certificate_arn       = module.certificate.certificate_arn
  canary_weight         = var.canary_weight
  deletion_protection   = var.alb_deletion_protection
  tags                  = local.tags
}

# orders.dev.example.com -> the load balancer. An alias record follows the
# load balancer's changing IP addresses automatically, and costs nothing.
resource "aws_route53_record" "site" {
  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.compute.alb_dns_name
    zone_id                = module.compute.alb_zone_id
    evaluate_target_health = true
  }
}

# ---------- the role ECS uses to start tasks ----------
# IAM is global, not regional. The name includes the region code, otherwise
# a second region would fail with "role already exists".

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- engineers' way in: Session Manager, not a bastion ----------

module "ops_access" {
  source = "../ops-access"
  count  = var.enable_ops_access ? 1 : 0

  name      = local.name
  vpc_id    = module.network.vpc_id
  subnet_id = module.network.app_subnet_ids[0]
  tags      = local.tags
}

# ---------- the service: a stable copy and a canary copy ----------

locals {
  # Only the app and the ops instance may reach the database.
  db_clients = concat([module.security_groups.app_id], module.ops_access[*].security_group_id)

  # When there's a database, ECS reads the password from Secrets Manager as the
  # task starts. It never appears in the task definition, the plan, or a log.
  app_env = var.enable_database ? {
    DB_HOST = module.database[0].address
    DB_NAME = module.database[0].database_name
  } : {}
  app_secrets = var.enable_database ? {
    DB_USER     = "${module.database[0].secret_arn}:username::"
    DB_PASSWORD = "${module.database[0].secret_arn}:password::"
  } : {}
}

module "orders" {
  source = "../ecs-service"

  for_each = {
    # Stable scales between desired_count and max_count on CPU.
    stable = { tag = var.stable_image_tag, count = var.desired_count, suffix = "", scaling = { min = var.desired_count, max = var.max_count, cpu_target = 60 } }
    # The canary always runs one task. Its share of traffic is set by canary_weight.
    canary = { tag = var.canary_image_tag, count = 1, suffix = "-canary", scaling = null }
  }

  name                  = "${local.name}-orders${each.value.suffix}"
  region                = var.region
  cluster_arn           = module.compute.cluster_arn
  cluster_name          = module.compute.cluster_name
  image                 = "${var.image_repository_url}:${each.value.tag}"
  cpu                   = var.cpu
  memory                = var.memory
  desired_count         = each.value.count
  autoscaling           = each.value.scaling
  subnet_ids            = local.task_subnet_ids
  security_group_id     = module.security_groups.app_id
  assign_public_ip      = local.assign_public_ip
  target_group_arn      = module.compute.target_group_arns[each.key]
  execution_role_arn    = aws_iam_role.execution.arn
  environment_variables = local.app_env
  secrets               = local.app_secrets
  log_retention_days    = var.log_retention_days
  tags                  = local.tags

  # Permissions must exist before any task tries to start — including the
  # right to read the database secret.
  depends_on = [aws_iam_role_policy_attachment.execution, aws_iam_role_policy.read_db_secret]
}

# ---------- alarms ----------

module "monitoring" {
  source = "../monitoring"

  name                     = local.name
  alert_email              = var.alert_email
  slo_availability_percent = var.slo_availability_percent
  alb_arn_suffix           = module.compute.alb_arn_suffix
  target_group_arn_suffix  = module.compute.target_group_arn_suffixes["stable"]
  cluster_name             = module.compute.cluster_name
  service_name             = module.orders["stable"].service_name
  db_instance_id           = var.enable_database ? "${local.name}-db" : null
  tags                     = local.tags
}
