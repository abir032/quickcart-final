output "alb_id" {
  description = "Security group for the load balancer"
  value       = aws_security_group.alb.id
}

output "app_id" {
  description = "Security group for the app tasks"
  value       = aws_security_group.app.id
}
