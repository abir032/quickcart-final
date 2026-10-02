# ---------- IAM roles for pods (EKS Pod Identity) ----------
# Three controllers call AWS APIs. Each gets its own role, scoped to its job,
# bound to one Kubernetes ServiceAccount. No access keys anywhere.
# This replaces the ECS "task role" idea: the permission belongs to a pod, not a node.

locals {
  workloads = merge(
    {
      # Creates and updates the ALB for every Ingress.
      load-balancer-controller = {
        namespace       = "kube-system"
        service_account = "aws-load-balancer-controller"
        policy          = file("${path.module}/policies/aws-load-balancer-controller.json")
      }
      # Writes the Route 53 record for every Ingress host name.
      external-dns = {
        namespace       = "external-dns"
        service_account = "external-dns"
        policy          = data.aws_iam_policy_document.external_dns.json
      }
    },
    # Copies the database secret into a Kubernetes Secret. Only with a database.
    length(var.secret_arns) == 0 ? {} : {
      external-secrets = {
        namespace       = "external-secrets"
        service_account = "external-secrets"
        policy          = data.aws_iam_policy_document.external_secrets[0].json
      }
    }
  )
}

data "aws_iam_policy_document" "pod_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# Route 53 changes only in our zone. Listing zones has no resource-level permission.
#trivy:ignore:AWS-0057
data "aws_iam_policy_document" "external_dns" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.dns_zone_id}"]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "external_secrets" {
  count = length(var.secret_arns) == 0 ? 0 : 1

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = var.secret_arns
  }
}

resource "aws_iam_role" "workload" {
  for_each = local.workloads

  name               = "${local.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
  tags               = var.tags
}

# The AWS Load Balancer Controller's policy is published by its maintainers and
# must create load balancers it can't know the names of in advance.
#trivy:ignore:AWS-0057
resource "aws_iam_role_policy" "workload" {
  for_each = local.workloads

  name   = each.key
  role   = aws_iam_role.workload[each.key].id
  policy = each.value.policy
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.workloads

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn
  tags            = var.tags

  depends_on = [aws_eks_addon.this]
}
