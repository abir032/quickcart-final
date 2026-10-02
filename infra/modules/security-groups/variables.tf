variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "vpc_id" {
  description = "The VPC the security groups belong to"
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's address range. The load balancer may only send traffic inside it."
  type        = string
}

variable "app_port" {
  description = "The port the app listens on inside its container"
  type        = number
  default     = 8080

  validation {
    condition     = var.app_port >= 1024 && var.app_port <= 65535
    error_message = "app_port must be 1024 or above. The container runs as a non-root user, which cannot use lower ports."
  }
}

variable "public_ingress_cidrs" {
  description = "Who may reach the load balancer. The whole internet for a public site."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
