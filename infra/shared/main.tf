# Things every environment and region shares. Applied once, rarely changed.

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "quickcart"
      ManagedBy = "terraform"
      Stack     = "shared"
    }
  }
}

resource "aws_ecr_repository" "orders" {
  name                 = "quickcart/orders"
  image_tag_mutability = "IMMUTABLE"

  # Lab: let destroy delete the repository with its images. In production, false.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "orders" {
  repository = aws_ecr_repository.orders.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  description = "Push images here. Every environment reads this value."
  value       = aws_ecr_repository.orders.repository_url
}

output "repository_name" {
  description = "Repository name, for ECR commands"
  value       = aws_ecr_repository.orders.name
}
