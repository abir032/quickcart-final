variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "vpc_id" {
  description = "VPC the instance lives in"
  type        = string
}

variable "subnet_id" {
  description = "A private app subnet. It needs a way out (NAT) to reach Systems Manager."
  type        = string
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
