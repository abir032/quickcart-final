output "jenkins_url" {
  description = "Open this in your browser. Only your IP can reach it."
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "webhook_url" {
  description = "Paste this into the GitHub repository's webhook settings"
  value       = "http://${aws_instance.jenkins.public_ip}:8080/github-webhook/"
}

output "instance_id" {
  description = "For connecting with Session Manager"
  value       = aws_instance.jenkins.id
}

output "backup_bucket" {
  description = "Where JENKINS_HOME backups go"
  value       = aws_s3_bucket.backup.bucket
}

output "sns_topic_arn" {
  description = "Pipeline notifications"
  value       = aws_sns_topic.pipeline.arn
}
