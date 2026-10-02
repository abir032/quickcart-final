output "alb_url" {
  description = "The site's address"
  value       = module.platform.alb_url
}

output "name" {
  description = "Name prefix for this environment"
  value       = module.platform.name
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = module.platform.cluster_name
}

output "stable_image_tag" {
  description = "Version serving normal traffic"
  value       = module.platform.stable_image_tag
}

output "canary_image_tag" {
  description = "Version the canary runs"
  value       = module.platform.canary_image_tag
}

output "canary_weight" {
  description = "Share of traffic on the canary"
  value       = module.platform.canary_weight
}

output "target_group_arns" {
  description = "Target groups, keyed stable and canary"
  value       = module.platform.target_group_arns
}

output "log_groups" {
  description = "Log groups, keyed stable and canary"
  value       = module.platform.log_groups
}

output "task_subnet_ids" {
  description = "Subnets tasks run in"
  value       = module.platform.task_subnet_ids
}

output "app_security_group_id" {
  description = "Security group for app and operations tasks"
  value       = module.platform.app_security_group_id
}

output "assign_public_ip" {
  description = "Whether tasks need a public IP"
  value       = module.platform.assign_public_ip
}

output "ops_sql_task_family" {
  description = "Task definition family for the safe SQL job"
  value       = module.platform.ops_sql_task_family
}

output "ops_sql_log_group" {
  description = "Where the safe SQL job's output goes"
  value       = module.platform.ops_sql_log_group
}

output "ops_instance_id" {
  description = "Session Manager target for reaching the database"
  value       = module.platform.ops_instance_id
}

output "db_address" {
  description = "Database host, reachable only inside the VPC"
  value       = module.platform.db_address
}

output "alerts_topic_arn" {
  description = "Where alarms go"
  value       = module.platform.alerts_topic_arn
}

output "alb_logs_bucket" {
  description = "Load balancer access logs"
  value       = module.platform.alb_logs_bucket
}
