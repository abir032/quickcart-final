variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in"
  type        = string
}

variable "subnet_ids" {
  description = "Data subnets, one per zone. They have no route out of the VPC."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "RDS needs subnets in at least two zones, even for a single-zone database."
  }
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to connect on 3306 — the app, and the operations task"
  type        = list(string)
}

variable "instance_class" {
  description = "Database size. db.t4g.micro is the smallest."
  type        = string
  default     = "db.t4g.micro"
}

variable "multi_az" {
  description = "Keep a standby copy in a second zone. Doubles the cost; true for production."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Refuse deletion, even from the console. True for production."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automatic backups. 0 turns backups off."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
