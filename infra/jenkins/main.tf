provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "quickcart"
      ManagedBy = "terraform"
      Stack     = "jenkins"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# GitHub publishes the addresses its webhooks come from. Reading them here
# means the security group stays correct without anyone copying a list.
data "http" "github_meta" {
  url = "https://api.github.com/meta"

  request_headers = {
    Accept = "application/json"
  }
}

locals {
  github_hook_cidrs = [
    for c in jsondecode(data.http.github_meta.response_body).hooks : c if !strcontains(c, ":")
  ]
}

# ---------- network access ----------

resource "aws_security_group" "jenkins" {
  name        = "qc-jenkins"
  description = "Jenkins: the web UI for you, webhooks for GitHub"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Jenkins UI from your IP only"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Webhooks from GitHub"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.github_hook_cidrs
  }

  # Accepted: Jenkins must reach GitHub, package repositories and AWS APIs.
  #trivy:ignore:AWS-0104
  egress {
    description = "all outbound: GitHub, AWS APIs, package downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- identity: a role, not stored keys ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "qc-jenkins"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Lab shortcut: Terraform creates VPCs, roles and load balancers, so the
# pipeline needs broad rights. In production, split this into a read-only
# role for plans and a separate, approved role per environment for applies.
resource "aws_iam_role_policy_attachment" "jenkins" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AdministratorAccess",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.jenkins.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "qc-jenkins"
  role = aws_iam_role.jenkins.name
}

# ---------- backups of JENKINS_HOME ----------

# Encrypted with S3's own keys (the default). A customer-managed KMS key adds
# control over who can decrypt, at extra cost. Accepted for this lab.
#trivy:ignore:AWS-0132
resource "aws_s3_bucket" "backup" {
  bucket = "qc-jenkins-backup-${data.aws_caller_identity.current.account_id}"

  # Lab: let destroy delete the backups with the bucket. In production, false.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "keep-30-days"
    status = "Enabled"

    filter {
      prefix = "jenkins-home/"
    }

    expiration {
      days = 30
    }
  }
}

# ---------- notifications ----------

# Encrypted with AWS's own SNS key. A customer-managed key adds control over
# who can decrypt, at extra cost. Accepted for this lab.
#trivy:ignore:AWS-0136
resource "aws_sns_topic" "pipeline" {
  name              = "quickcart-pipeline"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------- the controller ----------

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user-data.sh", {
    backup_bucket = aws_s3_bucket.backup.bucket
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "qc-jenkins"
  }
}
