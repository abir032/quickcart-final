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

variable "enable_service_alarms" {
  description = "Create the load balancer and service alarms. False when Terraform doesn't own the load balancer (on EKS a controller makes it). A plain true/false, because count must be known before apply and ARNs are not."
  type        = bool
  default     = true
}

variable "alb_arn_suffix" {
  description = "The load balancer, as CloudWatch names it. Null when enable_service_alarms is false."
  type        = string
  default     = null
}

variable "target_group_arn_suffix" {
  description = "The stable target group, as CloudWatch names it. Null when enable_service_alarms is false."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "ECS cluster name. Null when enable_service_alarms is false."
  type        = string
  default     = null
}

variable "service_name" {
  description = "The stable ECS service name. Null when enable_service_alarms is false."
  type        = string
  default     = null
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
