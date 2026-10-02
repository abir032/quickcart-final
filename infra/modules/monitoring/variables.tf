variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "alert_email" {
  description = "Who is told when an alarm fires. The subscription must be confirmed from the email."
  type        = string
}

variable "slo_availability_percent" {
  description = "The availability target. 99.5 means at most 0.5% of requests may fail."
  type        = number
  default     = 99.5

  validation {
    condition     = var.slo_availability_percent > 90 && var.slo_availability_percent < 100
    error_message = "slo_availability_percent must be between 90 and 100, for example 99.5."
  }
}

variable "alb_arn_suffix" {
  description = "The load balancer, as CloudWatch names it"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "The stable target group, as CloudWatch names it"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name"
  type        = string
}

variable "service_name" {
  description = "The stable ECS service name"
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance identifier. Null when there is no database."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
