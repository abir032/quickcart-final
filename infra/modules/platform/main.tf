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

  # Which compute platform runs the app. Everything below that only one
  # platform needs is switched on with these two flags.
  is_ecs = var.compute_platform == "ecs"
  is_eks = var.compute_platform == "eks"

  # With NAT, tasks run in private app subnets. Without it, they need public
  # subnets and a public IP to reach ECR. The security group still only lets
  # the load balancer in either way.
  task_subnet_ids  = var.enable_nat ? module.network.app_subnet_ids : module.network.public_subnet_ids
  assign_public_ip = !var.enable_nat
}

# ======================================================================
# Shared by both platforms: network, certificate, database, ops access, alarms
# ======================================================================

module "network" {
  source = "../network"

  name       = local.name
  cidr       = var.vpc_cidr
  enable_nat = var.enable_nat
  single_nat = var.single_nat
  tags       = local.tags
}

# ---------- a trusted certificate ----------
# ECS: Terraform attaches it to the listener. EKS: the Ingress names it, and
# the load balancer controller attaches it.

module "certificate" {
  source = "../certificate"

  domain_name = var.domain_name
  zone_id     = var.zone_id
  tags        = local.tags
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

locals {
  # Only the app and the ops instance may reach the database. On ECS the app is
  # the app security group; on EKS pods use the nodes' cluster security group.
  # Each is referenced by its one output, not as module.x[*]: a whole-module
  # reference would make the database wait for all of EKS, which waits for the
  # database — a dependency cycle.
  db_clients = concat(
    local.is_ecs ? [module.security_groups[0].app_id] : [],
    local.is_eks ? [module.eks[0].cluster_security_group_id] : [],
    var.enable_ops_access ? [module.ops_access[0].security_group_id] : [],
  )
}

# ======================================================================
# ECS on Fargate — only when compute_platform = "ecs"
# ======================================================================

module "security_groups" {
  source = "../security-groups"
  count  = local.is_ecs ? 1 : 0

  name     = local.name
  vpc_id   = module.network.vpc_id
  vpc_cidr = var.vpc_cidr
  tags     = local.tags
}

module "compute" {
  source = "../compute"
  count  = local.is_ecs ? 1 : 0

  name                  = local.name
  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security_groups[0].alb_id
  certificate_arn       = module.certificate.certificate_arn
  canary_weight         = var.canary_weight
  deletion_protection   = var.alb_deletion_protection
  tags                  = local.tags
}

# orders.dev.example.com -> the load balancer. An alias record follows the
# load balancer's changing IP addresses automatically, and costs nothing.
# (On EKS, ExternalDNS writes this record instead.)
resource "aws_route53_record" "site" {
  count = local.is_ecs ? 1 : 0

  zone_id = var.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = module.compute[0].alb_dns_name
    zone_id                = module.compute[0].alb_zone_id
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
  count = local.is_ecs ? 1 : 0

  name               = "${local.name}-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  count = local.is_ecs ? 1 : 0

  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- the service: a stable copy and a canary copy ----------

locals {
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

locals {
  ecs_services = {
    # Stable scales between desired_count and max_count on CPU.
    stable = { tag = var.stable_image_tag, count = var.desired_count, suffix = "", scaling = { min = var.desired_count, max = var.max_count, cpu_target = 60 } }
    # The canary always runs one task. Its share of traffic is set by canary_weight.
    canary = { tag = var.canary_image_tag, count = 1, suffix = "-canary", scaling = null }
  }
}

module "orders" {
  source = "../ecs-service"

  # Both services on ECS; none on EKS (the filter keeps the map's type intact).
  for_each = { for k, v in local.ecs_services : k => v if local.is_ecs }

  name                  = "${local.name}-orders${each.value.suffix}"
  region                = var.region
  cluster_arn           = module.compute[0].cluster_arn
  cluster_name          = module.compute[0].cluster_name
  image                 = "${var.image_repository_url}:${each.value.tag}"
  cpu                   = var.cpu
  memory                = var.memory
  desired_count         = each.value.count
  autoscaling           = each.value.scaling
  subnet_ids            = local.task_subnet_ids
  security_group_id     = module.security_groups[0].app_id
  assign_public_ip      = local.assign_public_ip
  target_group_arn      = module.compute[0].target_group_arns[each.key]
  execution_role_arn    = aws_iam_role.execution[0].arn
  environment_variables = local.app_env
  secrets               = local.app_secrets
  log_retention_days    = var.log_retention_days
  tags                  = local.tags

  # Permissions must exist before any task tries to start — including the
  # right to read the database secret.
  depends_on = [aws_iam_role_policy_attachment.execution, aws_iam_role_policy.read_db_secret]
}

# ======================================================================
# EKS + Argo CD — only when compute_platform = "eks"
# Terraform builds the cluster and its controllers; Argo CD deploys the app
# from the GitOps repository. Image tags live in Git, not in Terraform.
# ======================================================================

module "eks" {
  source = "../eks"
  count  = local.is_eks ? 1 : 0

  name                 = local.name
  environment          = var.environment
  region               = var.region
  vpc_id               = module.network.vpc_id
  subnet_ids           = module.network.app_subnet_ids
  kubernetes_version   = var.eks_kubernetes_version
  public_access_cidrs  = var.eks_public_access_cidrs
  admin_principal_arns = var.eks_admin_principal_arns
  node_instance_types  = var.eks_node_instance_types
  node_scaling         = var.eks_node_scaling
  log_retention_days   = var.log_retention_days
  dns_zone_name        = var.zone_name
  dns_zone_id          = var.zone_id
  secret_arns          = var.enable_database ? [module.database[0].secret_arn] : []
  gitops_repo_url      = var.gitops_repo_url
  gitops_revision      = var.gitops_revision
  tags                 = local.tags

  # Everything the chart in the GitOps repo needs that only Terraform knows.
  # The image TAG is not here: it lives in envs/<environment>/values.yaml.
  app_values = {
    image          = { repository = var.image_repository_url }
    host           = var.domain_name
    certificateArn = module.certificate.certificate_arn
    aws            = { region = var.region }
    autoscaling    = { minReplicas = var.desired_count, maxReplicas = var.max_count }
    database = var.enable_database ? {
      enabled   = true
      host      = module.database[0].address
      name      = module.database[0].database_name
      secretArn = module.database[0].secret_arn
      } : {
      enabled   = false
      host      = ""
      name      = ""
      secretArn = ""
    }
  }
}

# ---------- alarms ----------
# Load balancer and service alarms need resources Terraform owns, so they exist
# on ECS only. On EKS the controller owns the ALB; database alarms still apply.

module "monitoring" {
  source = "../monitoring"

  name                     = local.name
  alert_email              = var.alert_email
  slo_availability_percent = var.slo_availability_percent
  enable_service_alarms    = local.is_ecs
  alb_arn_suffix           = local.is_ecs ? module.compute[0].alb_arn_suffix : null
  target_group_arn_suffix  = local.is_ecs ? module.compute[0].target_group_arn_suffixes["stable"] : null
  cluster_name             = local.is_ecs ? module.compute[0].cluster_name : null
  service_name             = local.is_ecs ? module.orders["stable"].service_name : null
  db_instance_id           = var.enable_database ? "${local.name}-db" : null
  tags                     = local.tags
}
