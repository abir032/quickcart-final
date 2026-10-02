variable "name" {
  description = "Prefix for every resource name. Keep it short: load balancer and target group names are limited to 32 characters."
  type        = string

  validation {
    condition     = length(var.name) <= 20
    error_message = "name must be 20 characters or fewer, so names like <name>-canary stay under AWS's 32-character limit."
  }
}

variable "vpc_id" {
  description = "The VPC for the target groups"
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the load balancer, one per zone"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An application load balancer needs subnets in at least two zones."
  }
}

variable "alb_security_group_id" {
  description = "Security group for the load balancer"
  type        = string
}

variable "app_port" {
  description = "The port the targets listen on"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Page the load balancer checks. Must return 200 without touching a database."
  type        = string
  default     = "/health"
}

variable "canary_weight" {
  description = "Percentage of traffic sent to the canary target group. 0 means no canary."
  type        = number
  default     = 0

  validation {
    condition     = var.canary_weight >= 0 && var.canary_weight <= 100
    error_message = "canary_weight must be between 0 and 100."
  }
}

variable "certificate_arn" {
  description = "The HTTPS certificate, issued and validated by the certificate module"
  type        = string

  validation {
    condition     = startswith(var.certificate_arn, "arn:aws:acm:")
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "access_log_retention_days" {
  description = "How long to keep load balancer access logs in S3"
  type        = number
  default     = 30
}

variable "logs_force_destroy" {
  description = "Let terraform destroy delete the log bucket even when it holds logs. True for labs; false where logs are evidence."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Stop the load balancer being deleted. True for production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
