# ---------- the cluster ----------

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = var.tags
}

# ---------- access logs: every request, kept in S3 ----------
# Metrics say how many requests failed. Access logs say WHICH ones: path,
# client, status, and how long each part took. The first place to look in 5xx triage.

data "aws_caller_identity" "current" {}

# The AWS account that runs load balancers in this region. Only it may write logs.
data "aws_elb_service_account" "this" {}

# ALB access logs only support S3-managed encryption, so a customer-managed key isn't an option.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.name}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.logs_force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs.json
}

# ---------- the load balancer ----------

# Public by design: this is the site's front door.
#trivy:ignore:AWS-0053
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.deletion_protection

  # Reject requests with malformed headers instead of passing them to the app.
  # Closes off a class of request-smuggling attacks.
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  # AWS checks it may write to the bucket when logging is switched on.
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = var.tags
}

# Two target groups: "stable" serves normal traffic, "canary" receives a
# small share while a new version is tested. A5 uses the canary.
resource "aws_lb_target_group" "this" {
  for_each = toset(["stable", "canary"])

  name                 = "${var.name}-${each.key}"
  port                 = var.app_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.this["stable"].arn
        weight = 100 - var.canary_weight
      }

      target_group {
        arn    = aws_lb_target_group.this["canary"].arn
        weight = var.canary_weight
      }
    }
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
