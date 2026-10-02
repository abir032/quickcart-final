output "cluster_name" {
  description = "EKS cluster name, for aws eks update-kubeconfig"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API address"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "Cluster certificate authority, base64-encoded"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group EKS puts on the nodes. Pods use it, so the database must allow it."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "argocd_namespace" {
  description = "Namespace Argo CD runs in"
  value       = helm_release.argo_cd.namespace
}
