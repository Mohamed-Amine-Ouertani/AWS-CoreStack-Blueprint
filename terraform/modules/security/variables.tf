################################################################################
# Core identity variables — required for all resources
################################################################################

variable "project" {
  description = "Project name prefix applied to all resource names and tags"
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
  description = "AWS region (used for VPC endpoint service name and KMS key policy)"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Networking inputs — from networking module outputs
################################################################################

variable "vpc_id" {
  description = "VPC ID from networking module"
  type        = string
}

################################################################################
# EKS inputs
################################################################################

variable "eks_cluster_name" {
  description = "EKS cluster name. Used for SG tags and Cluster Autoscaler policy conditions."
  type        = string
}

variable "oidc_provider" {
  description = <<-EOT
    OIDC provider URL for IRSA trust policies — without the https:// prefix.
    Example: oidc.eks.eu-central-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE
    Leave empty on first apply (before EKS exists). Re-apply after EKS creates the OIDC provider.
  EOT
  type    = string
  default = ""

  validation {
    condition     = var.oidc_provider == "" || can(regex("^oidc\\.eks\\.", var.oidc_provider))
    error_message = "oidc_provider must be empty or a valid EKS OIDC URL (starting with oidc.eks.)"
  }
}

################################################################################
# S3 bucket ARNs — for IRSA policy scoping
# Passed from s3 module outputs. Each IRSA role is scoped to its own bucket.
################################################################################

variable "loki_bucket_arn" {
  description = "S3 bucket ARN for Loki log storage."
  type        = string
  default     = ""
}

variable "mimir_bucket_arn" {
  description = "S3 bucket ARN for Mimir metrics storage."
  type        = string
  default     = ""
}

variable "tempo_bucket_arn" {
  description = "S3 bucket ARN for Tempo trace storage."
  type        = string
  default     = ""
}

variable "private_route_table_ids" {
  description = "Private route table IDs from networking module. Used to attach the S3 Gateway VPC endpoint so EKS pod traffic to S3 bypasses NAT."
  type        = list(string)
  default     = []
}
