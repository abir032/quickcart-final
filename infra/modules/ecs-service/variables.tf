variable "name" {
  description = "Service name, also used for the task family and log group, for example qc-dev-use1-orders"
  type        = string
}

variable "region" {
  description = "Region, for the log configuration"
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster name, needed by auto scaling"
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster to run in"
  type        = string
}

variable "image" {
  description = "Full image address including tag, for example 126052242757.dkr.ecr.us-east-1.amazonaws.com/quickcart/orders:a1b2c3d"
  type        = string

  validation {
    condition     = can(regex(":[^/]+$", var.image)) && !endswith(var.image, ":latest")
    error_message = "image must include a tag, and the tag must not be latest. Use a version or a commit ID."
  }
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "CPU units for the task. 1024 is one vCPU."
  type        = number
  default     = 256

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.cpu)
    error_message = "cpu must be a Fargate size: 256, 512, 1024, 2048 or 4096."
  }
}

variable "memory" {
  description = "Memory for the task in MB. Must be a valid pairing with cpu."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "How many copies to START with. After creation, auto scaling (or nobody) owns the count — Terraform won't reset it."
  type        = number
  default     = 2

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count cannot be negative."
  }
}

variable "subnet_ids" {
  description = "Subnets the tasks run in"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the tasks"
  type        = string
}

variable "assign_public_ip" {
  description = "Give tasks a public IP. Needed when their subnets have no NAT, so they can pull images."
  type        = bool
  default     = false
}

variable "target_group_arn" {
  description = "Target group the tasks register with"
  type        = string
}

variable "execution_role_arn" {
  description = "Role ECS uses before the app starts: pull the image, write logs"
  type        = string
}

variable "task_role_arn" {
  description = "Role the app itself uses while running. Null when the app calls no AWS services."
  type        = string
  default     = null
}

variable "environment_variables" {
  description = "Plain settings for the container"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Settings read from Secrets Manager when a task starts, as NAME => secret ARN with key. Never visible in the task definition."
  type        = map(string)
  default     = {}
}

variable "autoscaling" {
  description = "Scale on CPU between min and max tasks. Null for a fixed count."
  type = object({
    min        = number
    max        = number
    cpu_target = number
  })
  default = null

  validation {
    condition     = var.autoscaling == null ? true : (var.autoscaling.min >= 1 && var.autoscaling.max >= var.autoscaling.min && var.autoscaling.cpu_target > 10 && var.autoscaling.cpu_target < 90)
    error_message = "autoscaling needs min of at least 1, max no lower than min, and cpu_target between 10 and 90."
  }
}

variable "log_retention_days" {
  description = "How long to keep logs"
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
