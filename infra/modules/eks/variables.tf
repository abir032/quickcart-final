variable "name" {
  description = "Prefix for every resource name, for example qc-dev-use1. The cluster is called <name>-eks."
  type        = string
}

variable "environment" {
  description = "dev, stg or prod. Picks envs/<environment>/values.yaml in the GitOps repository."
  type        = string
}

variable "region" {
  description = "AWS region, passed to the controllers that call AWS APIs"
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster and its load balancers live in"
  type        = string
}

variable "subnet_ids" {
  description = "Private app subnets for the control plane's network interfaces and the nodes. They need NAT to pull images and reach AWS APIs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version of the control plane. Check: aws eks describe-cluster-versions"
  type        = string
  default     = "1.36"
}

variable "public_access_cidrs" {
  description = "Who may reach the Kubernetes API from the internet (kubectl, terraform). Your own IP with /32. Jenkins does not need access: Argo CD deploys from inside."
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0 && !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "Give at least one address, and never 0.0.0.0/0 — that would open the cluster API to the whole internet."
  }
}

variable "admin_principal_arns" {
  description = "Extra IAM users or roles that get cluster-admin. Whoever runs the first apply is already an admin; don't list that identity again."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  description = "EC2 types for the managed node group. Must be allowed on your account; on the AWS Free plan c7i-flex.large is eligible."
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "node_scaling" {
  description = "Node count: the fewest, how many to start with, and the most"
  type = object({
    min     = number
    desired = number
    max     = number
  })
  default = { min = 1, desired = 2, max = 3 }

  validation {
    condition     = var.node_scaling.min >= 1 && var.node_scaling.min <= var.node_scaling.desired && var.node_scaling.desired <= var.node_scaling.max
    error_message = "node_scaling needs 1 <= min <= desired <= max."
  }
}

variable "log_retention_days" {
  description = "How long to keep the control plane's audit and API logs"
  type        = number
  default     = 7
}

variable "dns_zone_name" {
  description = "Hosted zone ExternalDNS may write records into, for example codeemit.com"
  type        = string
}

variable "dns_zone_id" {
  description = "ID of that hosted zone. ExternalDNS gets permission for this zone only."
  type        = string
}

variable "secret_arns" {
  description = "Secrets Manager secrets External Secrets may read — the database secret. Empty when there is no database."
  type        = list(string)
  default     = []
}

variable "gitops_repo_url" {
  description = "HTTPS address of the GitOps repository Argo CD watches, for example https://github.com/abir032/quickcart-gitops.git"
  type        = string

  validation {
    condition     = startswith(var.gitops_repo_url, "https://")
    error_message = "gitops_repo_url must be an https:// address."
  }
}

variable "gitops_revision" {
  description = "Branch Argo CD follows in the GitOps repository"
  type        = string
  default     = "main"
}

variable "app_values" {
  description = "Values only Terraform knows — image repository, host name, certificate, database address. Argo CD layers them over envs/<environment>/values.yaml."
  type        = any
  default     = {}
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for the cluster add-ons"
  type = object({
    aws_load_balancer_controller = string
    external_dns                 = string
    external_secrets             = string
    argo_cd                      = string
    argocd_apps                  = string
  })
  default = {
    aws_load_balancer_controller = "3.5.0"
    external_dns                 = "1.23.0"
    external_secrets             = "2.11.0"
    argo_cd                      = "10.9.6"
    argocd_apps                  = "2.0.6"
  }
}

variable "tags" {
  description = "Tags added to every resource"
  type        = map(string)
  default     = {}
}
