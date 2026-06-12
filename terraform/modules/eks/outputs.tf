################################################################################
# Cluster identity — consumed by all downstream modules
################################################################################

output "cluster_name" {
  description = "EKS cluster name. Passed to: RDS (for SG tag), monitoring (Helm provider), ALB controller."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint URL. Consumed by Helm and kubernetes Terraform providers in the monitoring module."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate. Consumed by Helm and kubernetes Terraform providers."
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "Active Kubernetes version. Used to pin Helm chart versions in monitoring module."
  value       = aws_eks_cluster.main.version
}

################################################################################
# OIDC — feeds back into security module (Phase 2 apply)
################################################################################

output "oidc_provider_arn" {
  description = "OIDC provider ARN. Passed to security module for IRSA trust policy construction."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL without https://. Passed to security module as var.oidc_provider for all IRSA assume-role conditions."
  value       = local.oidc_provider
}

################################################################################
# Node group
################################################################################

output "node_group_name" {
  description = "Managed node group name. Used in monitoring dashboards and runbooks."
  value       = aws_eks_node_group.main.node_group_name
}

output "node_group_arn" {
  description = "Managed node group ARN."
  value       = aws_eks_node_group.main.arn
}

output "node_group_status" {
  description = "Current node group status. Useful for health checks in CI."
  value       = aws_eks_node_group.main.status
}

output "launch_template_id" {
  description = "Launch template ID. Reference when adding additional node groups in future."
  value       = aws_launch_template.eks_nodes.id
}

output "launch_template_version" {
  description = "Latest launch template version. Bump to trigger a rolling node update."
  value       = aws_launch_template.eks_nodes.latest_version
}

################################################################################
# IRSA — EBS CSI (created in this module, not in security module)
################################################################################

output "irsa_ebs_csi_role_arn" {
  description = "IRSA role ARN for EBS CSI driver. Referenced in the ebs-csi addon's service_account_role_arn."
  value       = aws_iam_role.ebs_csi.arn
}
