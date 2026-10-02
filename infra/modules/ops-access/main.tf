# A tiny instance that lets engineers reach private resources — like the
# database — through Systems Manager Session Manager.
#
# Compared with a bastion host: no public IP, no SSH key to lose, no port 22
# open to anyone, and every session is logged in CloudTrail with who started it.

data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

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

resource "aws_iam_role" "this" {
  name               = "${var.name}-ops"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

# The only permission it needs: to be managed by Systems Manager.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-ops"
  role = aws_iam_role.this.name
}

resource "aws_security_group" "this" {
  name        = "${var.name}-ops"
  description = "Ops access instance: nothing may connect in"
  vpc_id      = var.vpc_id

  # No ingress block at all. Session Manager connections are started FROM the
  # instance, outbound, so no inbound port is ever needed.

  # Accepted: it must reach Systems Manager and the database.
  #trivy:ignore:AWS-0104
  egress {
    description = "outbound to Systems Manager and the database"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-ops" })
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.al2023_arm.id
  instance_type               = "t4g.micro"
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(var.tags, { Name = "${var.name}-ops" })
}
