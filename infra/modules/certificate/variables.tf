variable "domain_name" {
  description = "The full name the site is served on, for example orders.dev.example.com"
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a full lowercase host name, like orders.example.com."
  }
}

variable "zone_id" {
  description = "Route 53 hosted zone that owns the domain. The validation record is written there."
  type        = string
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
