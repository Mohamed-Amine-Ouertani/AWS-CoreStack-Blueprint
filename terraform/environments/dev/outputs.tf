################################################################################
# Networking
################################################################################

output "vpc_id" {
  description = "VPC ID. Passed to Project B when deploying additional workloads."
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs. Used by Project B for additional node groups or workloads."
  value       = module.networking.private_subnet_ids
}

output "nat_public_ips" {
  description = "NAT Gateway Elastic IPs. Add to allowlists in external services that restrict by source IP."
  value       = module.networking.nat_public_ips
}

################################################################################
# EKS — consumed by Project B (Kubernetes/Platform Engineering)
################################################################################

output "cluster_name" {
  description = "EKS cluster name. Use in: aws eks update-kubeconfig --name <value>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint. Consumed by Helm and Kubernetes providers in Project B."
  value       = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA. Consumed by kubeconfig and Terraform providers."
  value       = module.eks.cluster_ca_certificate
  sensitive   = true
}

output "cluster_version" {
  description = "Active Kubernetes version."
  value       = module.eks.cluster_version
}

output "oidc_provider_url" {
  description = <<-EOT
    EKS OIDC provider URL (without https://).
    Copy this value into terraform.tfvars as oidc_provider_url after Phase 2 apply,
    then re-apply to create IRSA trust policies (Phase 3).
  EOT
  value = module.eks.oidc_provider_url
}

output "oidc_provider_arn" {
  description = "EKS OIDC provider ARN. Needed when adding IRSA roles in Project B or C."
  value       = module.eks.oidc_provider_arn
}

output "node_group_name" {
  description = "Managed node group name. Reference in kubectl and monitoring dashboards."
  value       = module.eks.node_group_name
}

################################################################################
# kubectl config helper
################################################################################

output "kubectl_config_command" {
  description = "Run this command to configure kubectl after apply."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

################################################################################
# Security — IRSA ARNs consumed by Project B and C
################################################################################

output "irsa_aws_lbc_role_arn" {
  description = "IRSA role ARN for AWS Load Balancer Controller. Pass to the LBC Helm release in Project B."
  value       = module.security.irsa_aws_lbc_role_arn
}

output "irsa_cluster_autoscaler_role_arn" {
  description = "IRSA role ARN for Cluster Autoscaler. Pass to the CA Helm release in Project B."
  value       = module.security.irsa_cluster_autoscaler_role_arn
}

output "irsa_external_secrets_role_arn" {
  description = "IRSA role ARN for External Secrets Operator. Consumed in Project C (GitOps + Security)."
  value       = module.security.irsa_external_secrets_role_arn
}

output "kms_key_arn" {
  description = "KMS key ARN. Pass to Project B/C modules that need to create encrypted resources."
  value       = module.security.kms_key_arn
}

################################################################################
# RDS
################################################################################

output "rds_secret_arn" {
  description = "Secrets Manager ARN containing RDS connection details (JSON). Applications read this at startup."
  value       = module.rds.secret_arn
}

output "rds_secret_name" {
  description = "Secrets Manager secret name. Used in ESO ExternalSecret manifests in Project C."
  value       = module.rds.secret_name
}

output "rds_identifier" {
  description = "RDS instance identifier. Used in CloudWatch dashboards and runbooks."
  value       = module.rds.db_identifier
}

################################################################################
# ALB
################################################################################

output "alb_dns_name" {
  description = "ALB DNS name. Use to verify the load balancer is reachable before DNS propagation."
  value       = module.alb.alb_dns_name
}

output "apex_fqdn" {
  description = "Apex domain FQDN (e.g. example.com). Empty if create_dns_records = false."
  value       = module.alb.apex_fqdn
}

output "https_listener_arn" {
  description = "HTTPS listener ARN. Pass to AWS Load Balancer Controller Helm chart in Project B."
  value       = module.alb.https_listener_arn
}

################################################################################
# Monitoring — consumed by Project B and D
################################################################################

output "grafana_access_command" {
  description = "Port-forward command to access Grafana locally."
  value       = "kubectl port-forward svc/${module.monitoring.grafana_service_name} 3000:80 -n ${module.monitoring.monitoring_namespace}"
}

output "loki_gateway_url" {
  description = "Loki gateway URL (in-cluster). Applications send logs here via Alloy."
  value       = module.monitoring.loki_gateway_url
}

output "alloy_otlp_endpoint" {
  description = "Alloy OTLP gRPC endpoint (in-cluster). Instrument applications to send traces here."
  value       = module.monitoring.alloy_otlp_grpc_endpoint
}

################################################################################
# S3 — state bucket info
################################################################################

output "tfstate_bucket_id" {
  description = "Terraform state bucket name. Reference in CI/CD pipeline configuration."
  value       = module.s3.tfstate_bucket_id
}

output "access_logs_bucket_id" {
  description = "S3 access logs bucket name. Reference in ALB and future CloudFront distributions."
  value       = module.s3.access_logs_bucket_id
}
