# ---------- cluster add-ons, installed with Helm ----------
# Terraform installs the platform: the controllers every app relies on, and
# Argo CD. Argo CD then installs the app itself from the GitOps repository.
#
#   aws-load-balancer-controller  Ingress  -> ALB, target groups, listeners (Terraform did this for ECS)
#   external-dns                  Ingress host -> Route 53 record          (Terraform did this for ECS)
#   external-secrets              Secrets Manager -> Kubernetes Secret     (ECS did this natively)
#   argo-cd                       Git -> cluster: keeps the app matching the GitOps repo

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName = aws_eks_cluster.this.name
    region      = var.region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = local.workloads["load-balancer-controller"].service_account
    }
  })]

  depends_on = [aws_eks_pod_identity_association.workload]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.chart_versions.external_dns
  namespace        = local.workloads["external-dns"].namespace
  create_namespace = true

  values = [yamlencode({
    provider      = { name = "aws" }
    sources       = ["ingress"]
    domainFilters = [var.dns_zone_name]
    # Records it creates are marked with this owner, so it never touches
    # records it didn't make (like the zone's existing ones).
    txtOwnerId = aws_eks_cluster.this.name
    # sync = also delete the record when the Ingress goes away.
    policy = "sync"
    env    = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    serviceAccount = {
      create = true
      name   = local.workloads["external-dns"].service_account
    }
  })]

  depends_on = [aws_eks_pod_identity_association.workload]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets
  namespace        = "external-secrets"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      create = true
      name   = "external-secrets"
    }
  })]

  depends_on = [aws_eks_pod_identity_association.workload]
}

resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_versions.argo_cd
  namespace        = "argocd"
  create_namespace = true

  # Smaller footprint for a lab: no SSO server, no notification controller.
  # The UI is reached with kubectl port-forward, never exposed publicly.
  values = [yamlencode({
    dex           = { enabled = false }
    notifications = { enabled = false }
  })]

  depends_on = [aws_eks_addon.this]
}

# On destroy, the app's Application is removed first. Argo CD then deletes the
# app's Ingress, and the load balancer controller must still be running to
# delete the ALB it made — otherwise the ALB is orphaned and blocks the VPC.
# This pause gives that clean-up time before the controllers are removed.
resource "time_sleep" "app_cleanup" {
  destroy_duration = "150s"

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    helm_release.external_secrets,
    helm_release.argo_cd,
  ]
}

# ---------- the app, as an Argo CD Application ----------
# Tells Argo CD: render charts/orders from the GitOps repo with
# envs/<environment>/values.yaml (the image tag Jenkins updates), plus the
# values only Terraform knows, and keep namespace "orders" matching it.

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_versions.argocd_apps
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      "orders" = {
        namespace = "argocd"
        project   = "default"
        # Deleting the Application deletes everything it deployed.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "charts/orders"
          helm = {
            valueFiles   = ["../../envs/${var.environment}/values.yaml"]
            valuesObject = var.app_values
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "orders"
        }
        syncPolicy = {
          # prune: remove what was deleted from Git. selfHeal: undo manual changes.
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]

  depends_on = [time_sleep.app_cleanup]
}
