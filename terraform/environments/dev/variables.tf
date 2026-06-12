################################################################################
# Core identity
################################################################################

variable "project" {
  description = "Project name. Used as a prefix for all resource names and tags. Keep short (≤12 chars) — some AWS resource names have length limits."
  type        = string
  default     = "corestack"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,11}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, start with a letter, max 12 chars."
  }
}

variable "env" {
  description = "Deployment environment. Controls environment-specific behaviour: deletion protection, Multi-AZ, single NAT, etc."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod"
  }
}

variable "aws_region" {
  description = "AWS region to deploy into. eu-central-1 (Frankfurt) is the default — closest region to Tunisia with broad service availability."
  type        = string
  default     = "eu-central-1"
}

variable "github_org" {
  description = "GitHub organisation or username. Used in repository URL tags."
  type        = string
}

################################################################################
# Networking
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 provides 65,536 addresses — sufficient for 3 tiers × 3 AZs with room for future expansion."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to deploy into. Two is the minimum for HA. Adding a third requires no code changes — just add a third AZ here."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "single_nat_gateway" {
  description = "Use one shared NAT Gateway instead of one per AZ. Saves ~$32/month. Recommended: true for dev, false for prod."
  type        = bool
  default     = true   # dev default — saves money during portfolio demonstration
}

variable "flow_log_retention_days" {
  description = "CloudWatch log retention for VPC Flow Logs in days."
  type        = number
  default     = 30
}

################################################################################
# Two-phase apply — OIDC provider URL
#
# Leave empty ("") on Phase 1 apply. After Phase 2 (eks apply), run:
#   terraform output -raw oidc_provider_url
# Then set the value here and re-apply (Phase 3) to create IRSA trust policies.
################################################################################

variable "oidc_provider_url" {
  description = <<-EOT
    EKS OIDC provider URL without https:// prefix.
    Example: oidc.eks.eu-central-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE
    Leave empty ("") on Phase 1 apply. Populate after EKS cluster is created and
    re-apply to wire IRSA trust policies in the security module.
  EOT
  type    = string
  default = ""

  validation {
    condition     = var.oidc_provider_url == "" || can(regex("^oidc\\.eks\\.", var.oidc_provider_url))
    error_message = "oidc_provider_url must be empty or start with 'oidc.eks.' (no https:// prefix)."
  }
}

################################################################################
# EKS
################################################################################

variable "kubernetes_version" {
  description = "Kubernetes version. Check the EKS release calendar — each minor version has a 14-month standard support window."
  type        = string
  default     = "1.30"
}

variable "control_plane_log_retention_days" {
  description = "Retention for EKS control plane logs in CloudWatch. 90 days covers most audit lookback windows."
  type        = number
  default     = 90
}

variable "enable_public_eks_endpoint" {
  description = "Expose the Kubernetes API server publicly. True in dev for local kubectl access. False in prod — use VPN or bastion."
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Restrict to your IP in prod."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_group_name" {
  description = "Node group name suffix. Use descriptive names when running multiple groups."
  type        = string
  default     = "general"
}

variable "node_instance_types" {
  description = "EC2 instance types for the node group. Multiple types improve Cluster Autoscaler's ability to find Spot capacity."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot saves ~60% but requires PodDisruptionBudgets on workloads."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "Initial node count. Cluster Autoscaler manages this after first apply."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum nodes. Cluster Autoscaler will not scale below this."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum nodes. Set high enough for peak load."
  type        = number
  default     = 6
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size per node in GB."
  type        = number
  default     = 50
}

variable "cicd_role_arn" {
  description = "IAM role ARN for GitHub Actions CI/CD. Grants cluster-admin access via EKS Access Entry. Leave empty to skip."
  type        = string
  default     = ""
}

################################################################################
# RDS
################################################################################

variable "rds_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "15.7"
}

variable "rds_instance_class" {
  description = "RDS instance class. db.t3.micro for dev (~$25/mo Multi-AZ), db.t3.medium for prod (~$98/mo)."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage_gb" {
  description = "Initial storage in GB."
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage_gb" {
  description = "Storage autoscaling ceiling in GB."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master database username. Cannot be a reserved PostgreSQL keyword."
  type        = string
  default     = "dbadmin"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ standby. True for prod, false for dev (saves ~$45/month)."
  type        = bool
  default     = false   # dev default
}

variable "rds_backup_retention_days" {
  description = "Days to retain automated backups."
  type        = number
  default     = 7
}

variable "rds_pi_retention_days" {
  description = "Performance Insights retention. 7 = free tier, 31 = recommended."
  type        = number
  default     = 31
}

variable "rds_slow_query_threshold_ms" {
  description = "Log queries slower than this threshold (milliseconds)."
  type        = number
  default     = 1000
}

variable "rds_alarm_connections_threshold" {
  description = "CloudWatch alarm threshold for DatabaseConnections. ~80% of max_connections for the instance class."
  type        = number
  default     = 80
}

################################################################################
# ALB
################################################################################

variable "domain_name" {
  description = "Root domain for ACM certificate and Route53 records (e.g. example.com). Certificate covers both apex and wildcard."
  type        = string
}

variable "create_dns_records" {
  description = "Create Route53 records for ACM validation and ALB alias. Set false if Route53 is not the authoritative DNS."
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = "Path for ALB health checks. Should return 200-299."
  type        = string
  default     = "/healthz"
}

variable "waf_acl_arn" {
  description = "ARN of an existing WAFv2 WebACL to associate with the ALB. Leave empty to skip."
  type        = string
  default     = ""
}

################################################################################
# Observability — S3 retention
################################################################################

variable "loki_retention_days" {
  description = "Days to retain Loki chunks in S3."
  type        = number
  default     = 90
}

variable "mimir_retention_days" {
  description = "Days to retain Mimir metric blocks in S3."
  type        = number
  default     = 365
}

variable "tempo_retention_days" {
  description = "Days to retain Tempo trace data in S3."
  type        = number
  default     = 30
}

################################################################################
# Observability — Helm chart versions
################################################################################

variable "loki_chart_version" {
  type    = string
  default = "6.6.2"
}

variable "alloy_chart_version" {
  type    = string
  default = "0.4.0"
}

variable "mimir_chart_version" {
  type    = string
  default = "5.3.0"
}

variable "tempo_chart_version" {
  type    = string
  default = "1.10.1"
}

variable "prometheus_stack_chart_version" {
  type    = string
  default = "60.3.0"
}

################################################################################
# Observability — Loki and Tempo sizing
################################################################################

variable "loki_write_replicas" {
  type    = number
  default = 1
}

variable "loki_read_replicas" {
  type    = number
  default = 1
}

variable "loki_retention_hours" {
  description = "Loki log retention in hours. Must align with loki_retention_days × 24."
  type        = number
  default     = 2160   # 90 days
}

variable "tempo_retention_hours" {
  description = "Tempo trace retention in hours. Must align with tempo_retention_days × 24."
  type        = number
  default     = 720    # 30 days
}

################################################################################
# Grafana
################################################################################

variable "grafana_admin_password" {
  description = <<-EOT
    Grafana admin password. Do not hardcode — read from AWS Secrets Manager:
      export TF_VAR_grafana_admin_password=$(aws secretsmanager get-secret-value \
        --secret-id corestack/dev/grafana/admin --query SecretString --output text)
  EOT
  type      = string
  sensitive = true
}

################################################################################
# Alerting
################################################################################

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications (RDS + ALB). Leave empty to create SNS topics without subscriptions."
  type        = string
  default     = ""
}
