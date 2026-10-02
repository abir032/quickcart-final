output "name" {
  description = "The prefix used for every name in this environment"
  value       = local.name
}

output "alb_url" {
  description = "The site's address, with a trusted certificate"
  value       = "https://${var.domain_name}"
}

output "compute_platform" {
  description = "What runs the app: ecs or eks"
  value       = var.compute_platform
}

output "cluster_name" {
  description = "ECS cluster name, or EKS cluster name on eks"
  value       = local.is_ecs ? module.compute[0].cluster_name : module.eks[0].cluster_name
}

output "eks_cluster_name" {
  description = "EKS cluster name. Null on ecs."
  value       = local.is_eks ? module.eks[0].cluster_name : null
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API address. Null on ecs."
  value       = local.is_eks ? module.eks[0].cluster_endpoint : null
}

output "eks_cluster_ca" {
  description = "Cluster certificate authority, base64. Null on ecs."
  value       = local.is_eks ? module.eks[0].cluster_ca : null
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "azs" {
  description = "Availability zones in use"
  value       = module.network.azs
}

output "stable_image_tag" {
  description = "Version serving normal traffic"
  value       = var.stable_image_tag
}

output "canary_image_tag" {
  description = "Version the canary runs"
  value       = var.canary_image_tag
}

output "canary_weight" {
  description = "Share of traffic on the canary"
  value       = var.canary_weight
}

output "target_group_arns" {
  description = "Target groups, keyed stable and canary"
  value       = local.is_ecs ? module.compute[0].target_group_arns : null
}

output "log_groups" {
  description = "Log groups, keyed stable and canary"
  value       = { for k, m in module.orders : k => m.log_group_name }
}

# ---------- used by the operations jobs in A5 ----------

output "task_subnet_ids" {
  description = "Subnets tasks run in"
  value       = local.task_subnet_ids
}

output "app_security_group_id" {
  description = "Security group for app and operations tasks"
  value       = local.is_ecs ? module.security_groups[0].app_id : null
}

output "assign_public_ip" {
  description = "Whether tasks need a public IP"
  value       = local.assign_public_ip
}

output "ops_sql_task_family" {
  description = "Task definition family for the safe SQL job. Null when there is no database."
  value       = var.enable_database && local.is_ecs ? aws_ecs_task_definition.ops_sql[0].family : null
}

output "ops_sql_log_group" {
  description = "Where the safe SQL job's output goes"
  value       = var.enable_database && local.is_ecs ? aws_cloudwatch_log_group.ops_sql[0].name : null
}

output "ops_instance_id" {
  description = "Session Manager target for reaching the database. Null when ops access is off."
  value       = var.enable_ops_access ? module.ops_access[0].instance_id : null
}

output "db_address" {
  description = "Database host name, reachable only from inside the VPC"
  value       = var.enable_database ? module.database[0].address : null
}

output "alerts_topic_arn" {
  description = "Where this environment's alarms go"
  value       = module.monitoring.alerts_topic_arn
}

output "alb_logs_bucket" {
  description = "Load balancer access logs"
  value       = local.is_ecs ? module.compute[0].alb_logs_bucket : null
}
