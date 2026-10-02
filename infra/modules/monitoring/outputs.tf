output "alerts_topic_arn" {
  description = "Send anything else that needs a person here"
  value       = aws_sns_topic.alerts.arn
}

output "alarm_names" {
  description = "Every alarm this module created"
  value = concat(
    aws_cloudwatch_metric_alarm.error_rate[*].alarm_name,
    aws_cloudwatch_metric_alarm.unhealthy_targets[*].alarm_name,
    aws_cloudwatch_metric_alarm.service_cpu[*].alarm_name,
    aws_cloudwatch_metric_alarm.db_storage[*].alarm_name,
    aws_cloudwatch_metric_alarm.db_cpu[*].alarm_name,
  )
}
