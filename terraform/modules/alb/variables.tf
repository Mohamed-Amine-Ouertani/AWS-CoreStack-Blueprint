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

variable "vpc_id" {
  description = "VPC ID from networking module. Required for target group creation."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs from networking module. ALB is placed in public subnets — never private."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "At least 2 public subnets required for ALB across multiple AZs."
  }
}

variable "sg_alb_id" {
  description = "Security group ID for the ALB from security module (output: sg_alb_id). Allows 80/443 inbound from internet, outbound to EKS nodes."
  type        = string
}

################################################################################
# S3 access logs — from s3 module
################################################################################

variable "access_logs_bucket_id" {
  description = <<-EOT
    S3 bucket name (ID) for ALB access logs, from s3 module (output: access_logs_bucket_id).
    This module adds the required ELB service account bucket policy — the bucket
    must not already have a conflicting policy or the apply will fail.
  EOT
  type = string
}

################################################################################
# TLS and DNS
################################################################################

variable "domain_name" {
  description = "Root domain name for ACM certificate and Route53 records (e.g. example.com). The certificate will cover both example.com and *.example.com."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-\\.]+\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid domain (e.g. example.com)."
  }
}

variable "create_dns_records" {
  description = <<-EOT
    Create Route53 records for ACM validation, the apex domain, and the wildcard.
    Set false if:
      - Route53 is not the authoritative DNS for this domain
      - The hosted zone does not yet exist in this AWS account
      - You want to validate the ACM certificate via another DNS provider
    When false, the ACM certificate is still created but certificate_validation
    will block until DNS validation records are added manually.
  EOT
  type    = bool
  default = true
}

################################################################################
# Health check
################################################################################

variable "health_check_path" {
  description = "HTTP path the ALB uses to health-check targets. Must return 200-299. Use a dedicated /healthz endpoint that checks upstream dependencies."
  type        = string
  default     = "/healthz"
}

################################################################################
# Optional integrations
################################################################################

variable "waf_acl_arn" {
  description = "ARN of an existing WAFv2 WebACL to associate with the ALB. Leave empty to skip WAF association. The WebACL must be created in REGIONAL scope (not CLOUDFRONT)."
  type        = string
  default     = ""
}

################################################################################
# Alerting
################################################################################

variable "alarm_email" {
  description = "Email address for ALB CloudWatch alarm notifications. Leave empty to create the SNS topic without a subscription."
  type        = string
  default     = ""
}
