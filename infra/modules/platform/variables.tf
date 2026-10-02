variable "project" {
  description = "Short project code, used at the start of every name"
  type        = string
  default     = "qc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.project))
    error_message = "project must be 2 to 6 lowercase letters or digits, starting with a letter."
  }
}

variable "environment" {
  description = "Which environment this is"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "environment must be dev, stg or prod."
  }
}

variable "region" {
  description = "AWS region to build in"
  type        = string
}

variable "vpc_cidr" {
  description = "Address range for this environment's VPC. Give each environment and region its own, so they could be connected later."
  type        = string
}

variable "enable_nat" {
  description = "Build NAT gateways and run tasks in private subnets. About $32 a month per gateway."
  type        = bool
  default     = false
}

variable "single_nat" {
  description = "Share one NAT gateway across zones. Only used when enable_nat is true."
  type        = bool
  default     = true
}

variable "image_repository_url" {
  description = "ECR repository address, without a tag"
  type        = string
}

variable "stable_image_tag" {
  description = "Version serving normal traffic"
  type        = string

  validation {
    condition     = length(var.stable_image_tag) > 0 && var.stable_image_tag != "latest"
    error_message = "stable_image_tag must be a real version or commit ID, never latest."
  }
}

variable "canary_image_tag" {
  description = "Version the canary runs. Same as stable when there is no canary."
  type        = string

  validation {
    condition     = length(var.canary_image_tag) > 0 && var.canary_image_tag != "latest"
    error_message = "canary_image_tag must be a real version or commit ID, never latest."
  }
}

variable "canary_weight" {
  description = "Percentage of traffic sent to the canary"
  type        = number
  default     = 0

  validation {
    condition     = var.canary_weight >= 0 && var.canary_weight <= 50
    error_message = "canary_weight must be between 0 and 50. A canary is a small share; above that, promote instead."
  }
}

variable "desired_count" {
  description = "Stable tasks to start with, and the fewest auto scaling may go to. At least 2, so one zone can fail."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 2
    error_message = "desired_count must be at least 2, so the service survives losing a zone."
  }
}

variable "max_count" {
  description = "The most stable tasks auto scaling may run. Caps the cost of a traffic spike."
  type        = number
  default     = 4
}

variable "domain_name" {
  description = "Full host name for this environment, for example orders.dev.example.com"
  type        = string
}

variable "zone_id" {
  description = "Route 53 hosted zone that owns domain_name"
  type        = string
}

variable "alert_email" {
  description = "Who receives alarms for this environment"
  type        = string
}

variable "slo_availability_percent" {
  description = "Availability target for this environment"
  type        = number
  default     = 99.5
}

variable "enable_ops_access" {
  description = "Build the Session Manager instance engineers use to reach private resources. Needs enable_nat."
  type        = bool
  default     = true
}

variable "cpu" {
  description = "CPU units per task"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Memory per task in MB"
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "How long to keep logs"
  type        = number
  default     = 7
}

variable "alb_deletion_protection" {
  description = "Stop the load balancer being deleted"
  type        = bool
  default     = false
}

variable "enable_database" {
  description = "Build a MySQL database, connect the app to it, and add the operations task for safe SQL"
  type        = bool
  default     = true
}

variable "db_multi_az" {
  description = "Standby database copy in a second zone. True for production."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database. True for production."
  type        = bool
  default     = false
}
