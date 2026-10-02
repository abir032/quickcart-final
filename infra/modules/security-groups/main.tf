# The chain: internet -> load balancer -> app. Each group names the one before it.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Load balancer: HTTPS and HTTP from the internet"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = { "https" = 443, "http, redirected to https" = 80 }

    content {
      description = ingress.key
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.public_ingress_cidrs
    }
  }

  # Terraform, unlike the console, adds no outbound rule by itself.
  # Without this block the load balancer could not reach the app.
  # It only ever talks to targets inside the VPC, so that is all it may reach.
  egress {
    description = "to targets inside the VPC"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "App tasks: only the load balancer may connect"
  vpc_id      = var.vpc_id

  ingress {
    description     = "app port, from the load balancer only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Needed to pull images, write logs and read secrets. Accepted: with VPC
  # endpoints for ECR, CloudWatch and Secrets Manager this could be narrowed.
  #trivy:ignore:AWS-0104
  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-app" })
}
