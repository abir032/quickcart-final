# ---------- CloudTrail: who did what, in every region ----------
# Every API call in the account — console clicks, CLI, Terraform, Jenkins —
# recorded with who made it. The first thing asked in any security question.

data "aws_caller_identity" "current" {}

# CloudTrail can use a customer-managed KMS key; S3-managed encryption is accepted here.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "trail" {
  bucket = "qc-cloudtrail-${data.aws_caller_identity.current.account_id}"

  # Lab: let destroy delete the audit logs with the bucket. In production,
  # false — audit logs are evidence, and are often kept for years.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "trail" {
  statement {
    sid       = "CloudTrailCanCheckTheBucket"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "CloudTrailCanWriteLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail.json
}

# The trail's own log files are encrypted by S3; a KMS key is an optional extra.
#trivy:ignore:AWS-0015
resource "aws_cloudtrail" "account" {
  name                          = "quickcart-audit"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true

  # A signed digest file each hour proves the logs weren't edited afterwards.
  enable_log_file_validation = true

  depends_on = [aws_s3_bucket_policy.trail]
}

# ---------- a budget: find out about cost before the bill does ----------

resource "aws_budgets_budget" "monthly" {
  name         = "quickcart-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

output "cloudtrail_bucket" {
  description = "Where the audit trail is kept"
  value       = aws_s3_bucket.trail.bucket
}
