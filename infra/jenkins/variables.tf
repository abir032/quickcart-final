variable "my_ip_cidr" {
  description = "Your own public IP with /32 on the end, so only you can open Jenkins. Find it at https://checkip.amazonaws.com"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && endswith(var.my_ip_cidr, "/32")
    error_message = "my_ip_cidr must be a single address ending in /32, for example 203.0.113.25/32."
  }
}

variable "alert_email" {
  description = "Where pipeline notifications are sent. You must confirm the subscription email."
  type        = string
}

variable "instance_type" {
  description = "Jenkins controller size. t3.medium has room for Jenkins, Docker builds and Terraform at once."
  type        = string
  default     = "t3.medium"
}
