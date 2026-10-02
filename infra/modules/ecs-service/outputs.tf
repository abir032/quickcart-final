output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "The task definition revision now in use"
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "Where the app's logs go"
  value       = aws_cloudwatch_log_group.this.name
}

output "service_arn" {
  description = "ECS service ARN"
  value       = aws_ecs_service.this.id
}
