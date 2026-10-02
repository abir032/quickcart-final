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
  region                   = var.region
  vpc_cidr                 = var.vpc_cidr
  enable_nat               = var.enable_nat
  domain_name              = "${var.hostname}.${var.zone_name}"
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
}
