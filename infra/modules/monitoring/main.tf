# Alarms that match what customers feel, sent to email through SNS.

#trivy:ignore:AWS-0136
resource "aws_sns_topic" "alerts" {
  name              = "${var.name}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  error_budget_percent = 100 - var.slo_availability_percent
  alb_dims             = { LoadBalancer = var.alb_arn_suffix }
}

# The SLO alarm. Failed requests as a share of all requests, over 5 minutes.
# Counts both the app's errors and the load balancer's own (no task answered).
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  count = var.enable_service_alarms ? 1 : 0

  alarm_name          = "${var.name}-error-rate-above-slo"
  alarm_description   = "More than ${local.error_budget_percent}% of requests failed: the ${var.slo_availability_percent}% availability target is being missed."
  comparison_operator = "GreaterThanThreshold"
  threshold           = local.error_budget_percent
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * (FILL(app, 0) + FILL(lb, 0)) / requests"
    label       = "Failed requests (%)"
    return_data = true
  }

  metric_query {
    id = "app"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "lb"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dims
      period      = 300
      stat        = "Sum"
    }
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  count = var.enable_service_alarms ? 1 : 0

  alarm_name          = "${var.name}-unhealthy-targets"
  alarm_description   = "At least one task has failed its health check for 3 minutes."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "service_cpu" {
  count = var.enable_service_alarms ? 1 : 0

  alarm_name          = "${var.name}-service-cpu-high"
  alarm_description   = "Average CPU above 85% for 10 minutes, even with auto scaling. Check whether it has hit its maximum."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  count = var.db_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-db-storage-low"
  alarm_description   = "Less than 2 GB of database storage left."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count = var.db_instance_id == null ? 0 : 1

  alarm_name          = "${var.name}-db-cpu-high"
  alarm_description   = "Database CPU above 80% for 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}
