# ---------- the control plane ----------
# AWS runs the Kubernetes API servers and etcd. We choose the version, the
# subnets it attaches to, who may reach it, and how its secrets are encrypted.

locals {
  cluster_name = "${var.name}-eks"
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Kubernetes Secrets are stored in etcd. This key encrypts them a second time,
# so a copy of etcd alone reveals nothing.
resource "aws_kms_key" "secrets" {
  description             = "Encrypts Kubernetes secrets in ${local.cluster_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = var.tags
}

# EKS writes control plane logs here. Made first, so it has a retention period
# instead of keeping logs forever.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# The API is public, but only to the addresses in public_access_cidrs (your IP),
# so kubectl and Terraform work from a laptop. Nodes and Argo CD use the private
# endpoint inside the VPC. Production would make it private-only and reach it
# through a VPN or a host inside the VPC.
#trivy:ignore:AWS-0040
#trivy:ignore:AWS-0041
resource "aws_eks_cluster" "this" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Access is granted with EKS access entries (IAM principal -> Kubernetes
  # permissions), not the old aws-auth ConfigMap.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.secrets.arn
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# Extra administrators, for example a teammate. The identity that creates the
# cluster is made admin by bootstrap_cluster_creator_admin_permissions.
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  tags          = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ---------- the nodes ----------
# EC2 instances that run the pods. With ECS on Fargate there were no servers;
# here we pay for and size them, and AWS patches them (managed node group).

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = var.tags
}

# Join the cluster, run the pod network, pull images from ECR — the same job
# the ECS execution role did for image pulls.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.node_instance_types
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_scaling.min
    desired_size = var.node_scaling.desired
    max_size     = var.node_scaling.max
  }

  # Replace one node at a time during upgrades.
  update_config {
    max_unavailable = 1
  }

  # Like the ECS service's desired_count: once running, don't reset it on apply.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------- core add-ons, managed by EKS ----------
#   vpc-cni                 gives every pod a real VPC IP address
#   kube-proxy              routes traffic to Kubernetes Services
#   coredns                 DNS inside the cluster
#   eks-pod-identity-agent  hands pods their IAM role (see identities.tf)
#   metrics-server          CPU and memory figures for the HorizontalPodAutoscaler

resource "aws_eks_addon" "this" {
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "eks-pod-identity-agent", "metrics-server"])

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = var.tags

  # coredns and metrics-server are pods: they need nodes to run on.
  depends_on = [aws_eks_node_group.default]
}
