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

variable "kms_key_arn" {
  description = "KMS key ARN from the security module. Used to encrypt all buckets and the DynamoDB lock table."
  type        = string
}

################################################################################
# Observability retention — tuned per component access pattern
################################################################################

variable "loki_retention_days" {
  description = "Days to retain Loki log chunks in S3. Chunks transition to Standard-IA at day 30, expire at this value. Default 90 covers most incident lookback windows."
  type        = number
  default     = 90

  validation {
    condition     = var.loki_retention_days >= 30
    error_message = "loki_retention_days must be at least 30 (minimum before Standard-IA transition)."
  }
}

variable "mimir_retention_days" {
  description = "Days to retain Mimir metric blocks. Transitions: Standard-IA at day 14, Glacier IR at day 90. Default 365 covers a full year of capacity planning data."
  type        = number
  default     = 365

  validation {
    condition     = var.mimir_retention_days >= 14
    error_message = "mimir_retention_days must be at least 14 (minimum before Standard-IA transition)."
  }
}

variable "tempo_retention_days" {
  description = "Days to retain Tempo trace data. Transitions to Standard-IA at day 7. Default 30 — traces older than a month are rarely queried and expensive to store at volume."
  type        = number
  default     = 30

  validation {
    condition     = var.tempo_retention_days >= 7
    error_message = "tempo_retention_days must be at least 7 (minimum before Standard-IA transition)."
  }
}

################################################################################
# Bucket policies — requires IRSA role ARNs and VPC endpoint ID.
# These are passed from security module outputs after the second apply.
# Leave empty on first apply — policies are created conditionally via count.
################################################################################

variable "s3_vpc_endpoint_id" {
  description = "VPC endpoint ID for S3 (from security module). Used in bucket policies to deny non-VPC access to observability buckets. Leave empty on first apply."
  type        = string
  default     = ""
}

variable "loki_irsa_role_arn" {
  description = "IRSA role ARN for Loki (from security module). Used to scope the Loki bucket policy. Leave empty on first apply."
  type        = string
  default     = ""
}

variable "mimir_irsa_role_arn" {
  description = "IRSA role ARN for Mimir (from security module). Used to scope the Mimir bucket policy. Leave empty on first apply."
  type        = string
  default     = ""
}

variable "tempo_irsa_role_arn" {
  description = "IRSA role ARN for Tempo (from security module). Used to scope the Tempo bucket policy. Leave empty on first apply."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags applied to all resources. Merged with resource-specific tags."
  type        = map(string)
  default     = {}
}
