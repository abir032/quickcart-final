provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "quickcart"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Used only on EKS: Terraform installs the cluster add-ons and Argo CD with Helm.
# It signs in with the same AWS identity that runs Terraform. On ECS no Helm
# resources exist, so these settings are never used.
provider "helm" {
  kubernetes = {
    host                   = module.platform.eks_cluster_endpoint
    cluster_ca_certificate = module.platform.eks_cluster_ca == null ? null : base64decode(module.platform.eks_cluster_ca)
    exec = module.platform.eks_cluster_name == null ? null : {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.platform.eks_cluster_name, "--region", var.region]
    }
  }
}

# The image repository lives in the shared stack. Read its address from
# that stack's state instead of typing it.
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "shared/terraform.tfstate"
    region = "us-east-1"
  }
}

# The hosted zone already exists — Route 53 made it when the domain was
# registered. Look it up; never manage it from an environment.
data "aws_route53_zone" "main" {
  name         = var.zone_name
  private_zone = false
}

module "platform" {
  source = "../../../modules/platform"

  environment              = var.environment
  compute_platform         = var.compute_platform
  region                   = var.region
  vpc_cidr                 = var.vpc_cidr
  enable_nat               = var.enable_nat
  domain_name              = "${var.hostname}.${var.zone_name}"
  zone_name                = var.zone_name
  zone_id                  = data.aws_route53_zone.main.zone_id
  alert_email              = var.alert_email
  image_repository_url     = data.terraform_remote_state.shared.outputs.repository_url
  stable_image_tag         = var.stable_image_tag
  canary_image_tag         = var.canary_image_tag
  canary_weight            = var.canary_weight
  desired_count            = var.desired_count
  max_count                = var.max_count
  log_retention_days       = var.log_retention_days
  enable_database          = var.enable_database
  db_multi_az              = var.db_multi_az
  db_deletion_protection   = var.db_deletion_protection
  slo_availability_percent = var.slo_availability_percent

  # EKS only
  eks_public_access_cidrs  = var.eks_public_access_cidrs
  eks_admin_principal_arns = var.eks_admin_principal_arns
  eks_node_instance_types  = var.eks_node_instance_types
  eks_node_scaling         = var.eks_node_scaling
  gitops_repo_url          = var.gitops_repo_url
}
