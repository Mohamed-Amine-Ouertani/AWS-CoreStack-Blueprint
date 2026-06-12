output "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  value       = aws_kms_key.main.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.main.key_id
}

output "sg_alb_id" {
  description = "Security group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "sg_eks_nodes_id" {
  description = "Security group ID for EKS worker nodes"
  value       = aws_security_group.eks_nodes.id
}

output "sg_eks_control_plane_id" {
  description = "Security group ID for EKS control plane"
  value       = aws_security_group.eks_control_plane.id
}

output "sg_rds_id" {
  description = "Security group ID for RDS"
  value       = aws_security_group.rds.id
}

output "eks_cluster_role_arn" {
  description = "IAM role ARN for the EKS cluster"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN for EKS worker nodes"
  value       = aws_iam_role.eks_nodes.arn
}

output "irsa_aws_lbc_role_arn" {
  description = "IRSA role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.aws_lbc.arn
}

output "irsa_cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "irsa_loki_role_arn" {
  description = "IRSA role ARN for Loki S3 access"
  value       = aws_iam_role.loki.arn
}

output "irsa_mimir_role_arn" {
  description = "IRSA role ARN for Mimir S3 access"
  value       = aws_iam_role.mimir.arn
}

output "irsa_tempo_role_arn" {
  description = "IRSA role ARN for Tempo S3 access"
  value       = aws_iam_role.tempo.arn
}

output "irsa_external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator (consumed in Project C)"
  value       = aws_iam_role.external_secrets.arn
}

output "vpc_endpoint_s3_id" {
  description = "ID of the S3 Gateway VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

output "kms_key_alias" {
  description = "KMS key alias name"
  value       = aws_kms_alias.main.name
}
