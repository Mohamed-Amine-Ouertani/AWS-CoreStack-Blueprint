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

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

################################################################################
# Cluster config
################################################################################

variable "cluster_name" {
  description = "EKS cluster name. Used as prefix for all associated resources (node groups, addons, log groups, IRSA roles)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version. Check EKS release calendar before upgrading — each minor version has a 14-month standard support window."
  type        = string
  default     = "1.30"

  validation {
    condition     = can(regex("^1\\.(2[89]|[3-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be 1.28 or later (earlier versions are EOL on EKS)."
  }
}

variable "control_plane_log_retention_days" {
  description = "Retention period for EKS control plane logs in CloudWatch. 90 days covers most audit and incident lookback windows without excessive cost."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.control_plane_log_retention_days)
    error_message = "control_plane_log_retention_days must be a valid CloudWatch retention value."
  }
}

################################################################################
# Network inputs — from networking module
################################################################################

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes. Nodes must be in private subnets — public subnets expose node ports to the internet."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets required for HA node placement."
  }
}

variable "public_subnet_ids" {
  description = "Public subnet IDs. Listed in vpc_config so ALB controller can discover all AZ subnets, but control plane ENIs are placed in private subnets."
  type        = list(string)
}

################################################################################
# IAM inputs — from security module
################################################################################

variable "eks_cluster_role_arn" {
  description = "IAM role ARN for the EKS cluster control plane (from security module output eks_cluster_role_arn)."
  type        = string
}

variable "eks_node_role_arn" {
  description = "IAM role ARN for EKS worker nodes (from security module output eks_node_role_arn)."
  type        = string
}

variable "sg_control_plane_id" {
  description = "Security group ID for EKS control plane (from security module output sg_eks_control_plane_id)."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for EKS secret encryption and EBS node volume encryption (from security module output kms_key_arn)."
  type        = string
}

################################################################################
# API endpoint access
################################################################################

variable "enable_public_endpoint" {
  description = <<-EOT
    Enable the public Kubernetes API endpoint.
    true  = API reachable from internet (restricted by public_access_cidrs)
    false = API reachable only from within the VPC
    Recommended: true for dev (enables local kubectl), false for prod (requires VPN/bastion).
  EOT
  type    = bool
  default = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Tighten to your office/VPN CIDR in prod. Ignored when enable_public_endpoint = false."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrnetmask(c))])
    error_message = "All public_access_cidrs must be valid CIDR blocks."
  }
}

################################################################################
# Node group config
################################################################################

variable "node_group_name" {
  description = "Suffix appended to the node group name. Use descriptive names when running multiple node groups (e.g. 'general', 'compute', 'memory')."
  type        = string
  default     = "general"
}

variable "node_instance_types" {
  description = <<-EOT
    EC2 instance types for the managed node group. Providing multiple types
    improves Cluster Autoscaler's ability to find capacity, especially on Spot.
    All types must have similar vCPU/memory ratios to avoid scheduling imbalance.
    Dev default: t3.medium (2vCPU/4GB, ~$0.042/hr On-Demand in eu-central-1)
  EOT
  type    = list(string)
  default = ["t3.medium", "t3a.medium"]
}

variable "node_capacity_type" {
  description = <<-EOT
    ON_DEMAND or SPOT.
    SPOT: ~60-70% cheaper, but instances can be reclaimed with 2-min notice.
          Requires PodDisruptionBudgets and graceful termination handlers on workloads.
    ON_DEMAND: Recommended for prod workloads without disruption tolerance.
  EOT
  type    = string
  default = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "Initial node count. Ignored after first apply — Cluster Autoscaler manages desired_size out-of-band."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count. Cluster Autoscaler will not scale below this value."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count. Set high enough for peak load — Cluster Autoscaler cannot exceed this."
  type        = number
  default     = 6

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size must be >= node_min_size."
  }
}

variable "node_disk_size_gb" {
  description = "Root EBS volume size in GB per node. 50GB covers the base AMI (~8GB) plus image cache for typical workloads. Increase to 100GB for image-heavy clusters."
  type        = number
  default     = 50

  validation {
    condition     = var.node_disk_size_gb >= 20
    error_message = "node_disk_size_gb must be at least 20GB (EKS optimised AMI minimum)."
  }
}

################################################################################
# Optional inputs
################################################################################

variable "cicd_role_arn" {
  description = "IAM role ARN for CI/CD pipelines (e.g. GitHub Actions). If provided, an EKS Access Entry grants this role cluster-admin access for deployments. Leave empty to skip."
  type        = string
  default     = ""
}
