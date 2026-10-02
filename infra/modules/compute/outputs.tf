output "cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  description = "The load balancer's address"
  value       = aws_lb.this.dns_name
}

output "target_group_arns" {
  description = "Target group ARNs, keyed stable and canary"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "https_listener_arn" {
  description = "The HTTPS listener"
  value       = aws_lb_listener.https.arn
}

output "alb_arn_suffix" {
  description = "The load balancer, as CloudWatch names it"
  value       = aws_lb.this.arn_suffix
}

output "alb_zone_id" {
  description = "The load balancer's DNS zone, for Route 53 alias records"
  value       = aws_lb.this.zone_id
}

output "target_group_arn_suffixes" {
  description = "Target groups as CloudWatch names them, keyed stable and canary"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn_suffix }
}

output "alb_logs_bucket" {
  description = "Where load balancer access logs go"
  value       = aws_s3_bucket.alb_logs.bucket
}
