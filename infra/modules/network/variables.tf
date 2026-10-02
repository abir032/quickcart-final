variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1"
  type        = string
}

variable "cidr" {
  description = "The VPC's address range. A /16 gives room for every subnet this module makes."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 20
    error_message = "cidr must be a valid range of /20 or larger, for example 10.20.0.0/16."
  }
}

variable "az_count" {
  description = "How many availability zones to use. Two survives losing a whole zone."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3. One zone cannot survive a zone failure."
  }
}

variable "enable_nat" {
  description = "Build NAT gateways so app subnets can reach the internet. About $32 a month each. When false, app tasks run in public subnets instead."
  type        = bool
  default     = false
}

variable "single_nat" {
  description = "One NAT gateway shared by every zone. Cheaper, but if its zone fails the other zones lose outbound internet."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
