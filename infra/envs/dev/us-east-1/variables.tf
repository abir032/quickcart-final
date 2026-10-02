variable "state_bucket" {
  description = "The S3 bucket holding Terraform state, to read the shared stack"
  type        = string
}

variable "environment" {
  description = "dev or prod"
  type        = string
}

variable "compute_platform" {
  description = "What runs the app: ecs or eks"
  type        = string
  default     = "ecs"
}

variable "region" {
  description = "AWS region for this environment"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC address range. Unique per environment."
  type        = string
}

variable "enable_nat" {
  description = "Run tasks in private subnets behind a NAT gateway"
  type        = bool
  default     = true
}

variable "zone_name" {
  description = "Your domain's hosted zone, for example example.com"
  type        = string
}

variable "hostname" {
  description = "The part before the domain: orders.dev gives orders.dev.example.com"
  type        = string
}

variable "alert_email" {
  description = "Who receives this environment's alarms"
  type        = string
}

variable "desired_count" {
  description = "Fewest stable tasks"
  type        = number
  default     = 2
}

variable "max_count" {
  description = "Most stable tasks auto scaling may run"
  type        = number
  default     = 4
}

variable "log_retention_days" {
  description = "How long to keep app logs"
  type        = number
  default     = 7
}

variable "enable_database" {
  description = "Build the database and connect the app to it"
  type        = bool
  default     = true
}

variable "db_multi_az" {
  description = "Standby database in a second zone"
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Refuse to delete the database"
  type        = bool
  default     = false
}

variable "slo_availability_percent" {
  description = "Availability target"
  type        = number
  default     = 99.5
}

# Release settings. The pipeline passes these on every run.
variable "stable_image_tag" {
  description = "Version serving normal traffic"
  type        = string
}

variable "canary_image_tag" {
  description = "Version the canary runs"
  type        = string
}

variable "canary_weight" {
  description = "Percentage of traffic on the canary"
  type        = number
  default     = 0
}

# EKS settings. Only used when compute_platform = "eks".
variable "eks_public_access_cidrs" {
  description = "Addresses allowed to reach the Kubernetes API: your IP with /32"
  type        = list(string)
  default     = []
}

variable "eks_admin_principal_arns" {
  description = "Extra IAM users or roles given cluster-admin"
  type        = list(string)
  default     = []
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the nodes"
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "eks_node_scaling" {
  description = "Node count: min, desired, max"
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = { min = 1, desired = 2, max = 3 }
}

variable "gitops_repo_url" {
  description = "HTTPS address of the GitOps repository Argo CD deploys from"
  type        = string
  default     = ""
}
