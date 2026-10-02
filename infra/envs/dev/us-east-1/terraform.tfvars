state_bucket = "qc-tfstate-126052242757"

environment = "dev"

# What runs the app. "ecs" = ECS on Fargate, released by Terraform (Jenkinsfile).
# "eks" = Kubernetes, released by Argo CD from the GitOps repo (Jenkinsfile.eks).
# Also fill in the EKS block at the bottom.
compute_platform = "ecs"

region     = "us-east-1"
vpc_cidr   = "10.10.0.0/16"
enable_nat = true

zone_name   = "codeemit.com"
hostname    = "orders.dev"
alert_email = "fahim.faez@bjitgroup.com"

desired_count      = 2
max_count          = 4
log_retention_days = 7

enable_database        = true
db_multi_az            = false
db_deletion_protection = false

slo_availability_percent = 99.0

stable_image_tag = "v2"
canary_image_tag = "v2"
canary_weight    = 0

# ---------- EKS only (compute_platform = "eks") ----------
# eks_public_access_cidrs = ["<your-public-ip>/32"]   # curl https://checkip.amazonaws.com
# gitops_repo_url         = "https://github.com/abir032/quickcart-gitops.git"
# eks_node_scaling        = { min = 1, desired = 2, max = 3 }
