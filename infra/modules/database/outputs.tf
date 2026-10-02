output "address" {
  description = "Host name to connect to"
  value       = aws_db_instance.this.address
}

output "database_name" {
  description = "The database created inside the instance"
  value       = aws_db_instance.this.db_name
}

output "secret_arn" {
  description = "Secrets Manager secret holding the username and password"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
