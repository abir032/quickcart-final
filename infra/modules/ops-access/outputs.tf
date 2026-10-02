output "instance_id" {
  description = "Target for aws ssm start-session"
  value       = aws_instance.this.id
}

output "security_group_id" {
  description = "Give this group access to anything engineers must reach, such as the database"
  value       = aws_security_group.this.id
}
