output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "azs" {
  description = "The availability zones in use"
  value       = local.azs
}

output "public_subnet_ids" {
  description = "One public subnet per zone, for the load balancer"
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "app_subnet_ids" {
  description = "One app subnet per zone. Only reach the internet when enable_nat is true."
  value       = [for az in local.azs : aws_subnet.app[az].id]
}

output "data_subnet_ids" {
  description = "One data subnet per zone. No route out of the VPC."
  value       = [for az in local.azs : aws_subnet.data[az].id]
}

output "nat_enabled" {
  description = "Whether app subnets have a way out to the internet"
  value       = var.enable_nat
}
