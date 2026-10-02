# Runs plans against a mocked AWS: no account, no cost, no waiting.
# Asserts only check values known at plan time — names, counts, settings —
# never ARNs or IDs, which AWS only creates during apply.

mock_provider "helm" {}
mock_provider "time" {}

mock_provider "aws" {
  # Values AWS would normally create. ARNs must look real, because the
  # provider checks their format even in a mocked plan.
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "126052242757" }
  }
  mock_data "aws_elb_service_account" {
    defaults = { arn = "arn:aws:iam::126052242757:root" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:126052242757:loadbalancer/app/test/abc", arn_suffix = "app/test/abc" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:126052242757:targetgroup/test/abc", arn_suffix = "targetgroup/test/abc" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:126052242757:certificate/abc"
      domain_validation_options = [{
        domain_name           = "orders.dev.example.com"
        resource_record_name  = "_abc.orders.dev.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_xyz.acm-validations.aws."
      }]
    }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn      = "arn:aws:eks:us-east-1:111122223333:cluster/test"
      endpoint = "https://ABC.gr7.us-east-1.eks.amazonaws.com"
      certificate_authority = [{
        data = "dGVzdA=="
      }]
    }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111122223333:key/abc" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::126052242757:role/test" }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = { arn = "arn:aws:ecs:us-east-1:126052242757:cluster/test" }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn = "arn:aws:ecs:us-east-1:126052242757:task-definition/test:1" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:126052242757:test" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::test-bucket" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:126052242757:log-group:test" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address = "qc-dev-use1-db.abc.us-east-1.rds.amazonaws.com"
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-1:126052242757:secret:rds!db-abc"
        secret_status = "active"
        kms_key_id    = ""
      }]
    }
  }
}

variables {
  environment          = "dev"
  region               = "us-east-1"
  vpc_cidr             = "10.10.0.0/16"
  enable_nat           = true
  domain_name          = "orders.dev.example.com"
  zone_name            = "example.com"
  zone_id              = "Z0123456789ABC"
  alert_email          = "ops@example.com"
  image_repository_url = "126052242757.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders"
  stable_image_tag     = "v1"
  canary_image_tag     = "v1"
}

run "names_include_environment_and_region" {
  command = plan
  assert {
    condition     = output.name == "qc-dev-use1"
    error_message = "Expected the name prefix qc-dev-use1, got ${output.name}"
  }
}

run "site_is_served_on_its_domain" {
  command = plan
  assert {
    condition     = output.alb_url == "https://orders.dev.example.com"
    error_message = "The site should be served on its own domain name"
  }
}

run "tasks_run_privately_behind_nat" {
  command = plan
  assert {
    condition     = local.assign_public_ip == false
    error_message = "With NAT, tasks must not get public IPs"
  }
}

run "no_nat_means_public_ip_for_tasks" {
  command = plan
  variables {
    enable_nat        = false
    enable_ops_access = false
  }
  assert {
    condition     = local.assign_public_ip == true
    error_message = "Without NAT, tasks need a public IP to pull images"
  }
}

run "session_manager_access_by_default" {
  command = plan
  assert {
    condition     = length(module.ops_access) == 1
    error_message = "The Session Manager instance should exist by default"
  }
}

run "database_and_ops_task_by_default" {
  command = plan
  assert {
    condition     = output.ops_sql_task_family == "qc-dev-use1-ops-sql"
    error_message = "Expected the operations task family qc-dev-use1-ops-sql"
  }
}

run "five_alarms_with_a_database" {
  command = plan
  assert {
    condition     = length(module.monitoring.alarm_names) == 5
    error_message = "Expected SLO, unhealthy targets, service CPU, database storage and database CPU alarms"
  }
}

run "three_alarms_without_a_database" {
  command = plan
  variables {
    enable_database = false
  }
  assert {
    condition     = length(module.monitoring.alarm_names) == 3 && output.ops_sql_task_family == null
    error_message = "Without a database: three alarms and no operations task"
  }
}

run "canary_off_by_default" {
  command = plan
  assert {
    condition     = output.canary_weight == 0
    error_message = "With no canary settings, the canary must get no traffic"
  }
}

run "canary_at_ten_percent" {
  command = plan
  variables {
    canary_image_tag = "a1b2c3d"
    canary_weight    = 10
  }
  assert {
    condition     = output.canary_image_tag == "a1b2c3d" && output.canary_weight == 10
    error_message = "A 10% canary should plan with the canary's version and weight"
  }
}

run "rejects_one_task" {
  command = plan
  variables {
    desired_count = 1
  }
  expect_failures = [var.desired_count]
}

run "rejects_unknown_environment" {
  command = plan
  variables {
    environment = "production"
  }
  expect_failures = [var.environment]
}

run "rejects_latest_tag" {
  command = plan
  variables {
    stable_image_tag = "latest"
  }
  expect_failures = [var.stable_image_tag]
}

run "rejects_canary_over_50" {
  command = plan
  variables {
    canary_weight = 80
  }
  expect_failures = [var.canary_weight]
}

# ---------- compute_platform = "eks" ----------

run "ecs_is_the_default" {
  command = plan
  assert {
    condition     = output.compute_platform == "ecs" && length(module.eks) == 0 && length(module.compute) == 1
    error_message = "Without compute_platform, the app should run on ECS and no EKS cluster should be planned"
  }
}

run "eks_replaces_ecs" {
  command = plan
  variables {
    compute_platform        = "eks"
    gitops_repo_url         = "https://github.com/example/quickcart-gitops.git"
    eks_public_access_cidrs = ["203.0.113.25/32"]
  }
  assert {
    condition     = length(module.eks) == 1 && length(module.compute) == 0 && length(module.orders) == 0 && length(module.security_groups) == 0
    error_message = "On eks: one EKS cluster, and no ECS cluster, services or ECS security groups"
  }
  assert {
    condition     = output.eks_cluster_name == "qc-dev-use1-eks"
    error_message = "The EKS cluster should be named <prefix>-eks"
  }
}

run "eks_keeps_only_database_alarms" {
  command = plan
  variables {
    compute_platform        = "eks"
    gitops_repo_url         = "https://github.com/example/quickcart-gitops.git"
    eks_public_access_cidrs = ["203.0.113.25/32"]
  }
  assert {
    condition     = length(module.monitoring.alarm_names) == 2 && output.ops_sql_task_family == null
    error_message = "On eks the load balancer belongs to a controller: only the two database alarms, and no ECS ops task"
  }
}

run "eks_needs_gitops_repo_and_api_cidrs" {
  command = plan
  variables {
    compute_platform = "eks"
  }
  expect_failures = [var.compute_platform]
}

run "eks_needs_nat" {
  command = plan
  variables {
    compute_platform        = "eks"
    enable_nat              = false
    enable_ops_access       = false
    gitops_repo_url         = "https://github.com/example/quickcart-gitops.git"
    eks_public_access_cidrs = ["203.0.113.25/32"]
  }
  expect_failures = [var.compute_platform]
}

run "eks_api_never_open_to_the_internet" {
  command = plan
  variables {
    compute_platform        = "eks"
    gitops_repo_url         = "https://github.com/example/quickcart-gitops.git"
    eks_public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.eks_public_access_cidrs]
}
