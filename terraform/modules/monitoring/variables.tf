################################################################################
# Core identity
################################################################################

variable "project" {
  description = "Project name prefix"
  type        = string
}

variable "env" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod"
  }
}

variable "aws_region" {
  description = "AWS region. Used in Loki, Mimir, and Tempo S3 storage config."
  type        = string
}

variable "domain_name" {
  description = "Root domain name. Used to set Grafana's root_url so internal links resolve correctly."
  type        = string
}

variable "tags" {
  description = "Common tags (applied to AWS resources created by this module)"
  type        = map(string)
  default     = {}
}

################################################################################
# EKS inputs — from eks module outputs
################################################################################

variable "kms_key_arn" {
  description = "KMS key ARN for gp3 StorageClass volume encryption (from security module)."
  type        = string
}

################################################################################
# S3 bucket names — from s3 module outputs
################################################################################

variable "loki_bucket_name" {
  description = "S3 bucket name for Loki chunk storage (s3 module output: loki_bucket_id)."
  type        = string
}

variable "mimir_bucket_name" {
  description = "S3 bucket name for Mimir block storage (s3 module output: mimir_bucket_id)."
  type        = string
}

variable "tempo_bucket_name" {
  description = "S3 bucket name for Tempo trace storage (s3 module output: tempo_bucket_id)."
  type        = string
}

################################################################################
# IRSA role ARNs — from security module outputs (after Phase 2 apply)
################################################################################

variable "irsa_loki_role_arn" {
  description = "IRSA role ARN for Loki S3 access (security module output: irsa_loki_role_arn)."
  type        = string
}

variable "irsa_mimir_role_arn" {
  description = "IRSA role ARN for Mimir S3 access (security module output: irsa_mimir_role_arn)."
  type        = string
}

variable "irsa_tempo_role_arn" {
  description = "IRSA role ARN for Tempo S3 access (security module output: irsa_tempo_role_arn)."
  type        = string
}

################################################################################
# Grafana
################################################################################

variable "grafana_admin_password" {
  description = "Grafana admin password. Store in AWS Secrets Manager and pass via a data source — do not hardcode in tfvars. Mark sensitive in root module."
  type        = string
  sensitive   = true
}

################################################################################
# Chart versions — pin all charts explicitly
# Update these in a dedicated PR to control when chart upgrades happen.
################################################################################

variable "loki_chart_version" {
  description = "Helm chart version for Loki. Check https://github.com/grafana/loki/releases"
  type        = string
  default     = "6.6.2"
}

variable "alloy_chart_version" {
  description = "Helm chart version for Grafana Alloy (replaces Promtail). Check https://github.com/grafana/alloy/releases"
  type        = string
  default     = "0.4.0"
}

variable "mimir_chart_version" {
  description = "Helm chart version for mimir-distributed. Check https://github.com/grafana/mimir/releases"
  type        = string
  default     = "5.3.0"
}

variable "tempo_chart_version" {
  description = "Helm chart version for Tempo. Check https://github.com/grafana/tempo/releases"
  type        = string
  default     = "1.10.1"
}

variable "prometheus_stack_chart_version" {
  description = "Helm chart version for kube-prometheus-stack. Check https://github.com/prometheus-community/helm-charts/releases"
  type        = string
  default     = "60.3.0"
}

################################################################################
# Loki sizing
################################################################################

variable "loki_write_replicas" {
  description = "Loki write component replicas. 1 for dev, 2+ for prod HA."
  type        = number
  default     = 1
}

variable "loki_read_replicas" {
  description = "Loki read component replicas. 1 for dev, 2+ for prod HA."
  type        = number
  default     = 1
}

variable "loki_retention_hours" {
  description = "Loki log retention in hours. Default 2160 = 90 days. Must align with S3 lifecycle rule."
  type        = number
  default     = 2160
}

################################################################################
# Tempo sizing
################################################################################

variable "tempo_retention_hours" {
  description = "Tempo trace retention in hours. Default 720 = 30 days. Must align with S3 lifecycle rule."
  type        = number
  default     = 720
}
