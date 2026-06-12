################################################################################
# Core identity
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

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Network inputs — from networking and security modules
################################################################################

variable "database_subnet_ids" {
  description = "Database tier subnet IDs from networking module (output: database_subnet_ids). Must be isolated from public and private EKS subnets."
  type        = list(string)

  validation {
    condition     = length(var.database_subnet_ids) >= 2
    error_message = "At least 2 database subnets required for Multi-AZ and subnet group."
  }
}

variable "sg_rds_id" {
  description = "RDS security group ID from security module (output: sg_rds_id). Allows inbound 5432 from EKS nodes only."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for storage encryption, Performance Insights, and Secrets Manager (from security module output: kms_key_arn)."
  type        = string
}

################################################################################
# Engine
################################################################################

variable "engine_version" {
  description = <<-EOT
    PostgreSQL engine version. The major version determines the parameter group
    family (e.g. "15.7" → family "postgres15"). 
    Check RDS release notes before upgrading — major version upgrades require
    a maintenance window and ~5-10 min downtime even with Multi-AZ.
  EOT
  type    = string
  default = "15.7"

  validation {
    condition     = can(regex("^1[0-9]\\.", var.engine_version))
    error_message = "engine_version must be a valid PostgreSQL version string (e.g. 15.7, 16.2)."
  }
}

################################################################################
# Compute and storage
################################################################################

variable "instance_class" {
  description = <<-EOT
    RDS instance class. Cost guidance (eu-central-1 On-Demand, Multi-AZ pricing):
      db.t3.micro  — $25/mo  — dev only, burstable, no baseline guarantee
      db.t3.small  — $50/mo  — staging, light prod read workloads
      db.t3.medium — $98/mo  — small prod, < 100 concurrent connections
      db.m6g.large — $234/mo — production baseline, consistent performance
  EOT
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage_gb" {
  description = "Initial storage allocation in GB. RDS autoscaling handles growth up to max_allocated_storage_gb — the initial value only needs to cover the first days."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage_gb >= 20
    error_message = "allocated_storage_gb must be at least 20 GB (PostgreSQL minimum on gp3)."
  }
}

variable "max_allocated_storage_gb" {
  description = "Maximum storage autoscaling ceiling in GB. RDS scales up automatically when free space falls below 10% or 5 GB. Set to 0 to disable autoscaling (not recommended)."
  type        = number
  default     = 100

  validation {
    condition     = var.max_allocated_storage_gb >= var.allocated_storage_gb
    error_message = "max_allocated_storage_gb must be >= allocated_storage_gb."
  }
}

################################################################################
# Database credentials
################################################################################

variable "db_name" {
  description = "Name of the initial database created on the instance."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "db_name must start with a letter and contain only alphanumeric characters and underscores."
  }
}

variable "db_username" {
  description = "Master username for the RDS instance. Cannot be 'admin', 'postgres', or other reserved words. Used in the Secrets Manager secret."
  type        = string
  default     = "dbadmin"

  validation {
    condition     = !contains(["admin", "postgres", "master", "root", "superuser"], var.db_username)
    error_message = "db_username uses a reserved PostgreSQL or RDS keyword. Choose a different name."
  }
}

################################################################################
# High availability
################################################################################

variable "multi_az" {
  description = <<-EOT
    Enable Multi-AZ deployment. Provisions a synchronous standby replica in a
    second AZ. Failover is automatic, typically completing in 60–120 seconds.
    Recommended: true for prod, false for dev (saves ~$45/month on t3.micro).
  EOT
  type    = bool
  default = true
}

################################################################################
# Backups and maintenance
################################################################################

variable "backup_retention_days" {
  description = "Number of days to retain automated backups. Minimum 7 for any environment with real data. Prod recommended: 14–30."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 1 and 35 (RDS maximum)."
  }
}

################################################################################
# Monitoring and alerting
################################################################################

variable "performance_insights_retention_days" {
  description = <<-EOT
    Performance Insights data retention in days.
      7   = free tier
      31  = ~$0.02/vCPU/month — recommended, covers most post-incident investigations
      731 = maximum, paid, for long-term query trend analysis
  EOT
  type    = number
  default = 31

  validation {
    condition     = contains([7, 31, 731], var.performance_insights_retention_days)
    error_message = "performance_insights_retention_days must be 7, 31, or 731 (valid RDS PI values)."
  }
}

variable "slow_query_threshold_ms" {
  description = "Queries slower than this value (in milliseconds) are written to the PostgreSQL log. 1000ms is a conservative starting point — lower to 200ms once baseline is established."
  type        = number
  default     = 1000
}

variable "alarm_email" {
  description = "Email address for RDS CloudWatch alarm notifications via SNS. Leave empty to create the SNS topic without a subscription (wire externally)."
  type        = string
  default     = ""
}

variable "alarm_connections_threshold" {
  description = <<-EOT
    CloudWatch alarm threshold for DatabaseConnections metric.
    Rule of thumb: max_connections for PostgreSQL = LEAST(DBInstanceClassMemory/9531392, 5000).
    For db.t3.micro (~1GB): max ~112. Set threshold at ~80% of max.
    For db.t3.medium (~4GB): max ~420. Set threshold at ~80% of max.
  EOT
  type    = number
  default = 80
}
