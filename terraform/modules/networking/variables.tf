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

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives 256 /24 subnets — sufficient for 3 tiers across 3 AZs with room to spare."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zones" {
  description = "List of AZs to deploy into. Must contain at least 2 for HA. Adding a third AZ requires no code change — Terraform derives subnet CIDRs from count."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required for HA."
  }
  validation {
    condition     = length(var.availability_zones) <= 9
    error_message = "Maximum 9 AZs supported (subnet offset layout uses single digits)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use a single NAT Gateway shared across all AZs instead of one per AZ.
    Saves ~$32/month per additional AZ (NAT GW fixed cost + data processing).
    Trade-off: if the NAT GW's AZ has an outage, all private subnets lose egress.
    Recommended: true for dev/staging, false for prod.
  EOT
  type    = bool
  default = false
}

variable "flow_log_retention_days" {
  description = "CloudWatch log retention for VPC Flow Logs. 30 days balances audit requirements with cost. Increase to 90+ for compliance environments."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.flow_log_retention_days)
    error_message = "flow_log_retention_days must be a value accepted by CloudWatch (1, 3, 5, 7, 14, 30, 60, 90, ...)."
  }
}

variable "tags" {
  description = "Common tags applied to all resources. Merged with resource-specific tags — resource tags take precedence on conflicts."
  type        = map(string)
  default     = {}
}
