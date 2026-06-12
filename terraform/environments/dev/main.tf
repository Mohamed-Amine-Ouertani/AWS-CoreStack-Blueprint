################################################################################
# Locals — computed once, referenced everywhere
################################################################################

locals {
  # Cluster name is derived here so both the security module (for SG tags) and
  # the eks module receive identical values without repeating the formula.
  cluster_name = "${var.project}-${var.env}"

  # Common tags applied to every resource via the AWS provider default_tags
  # block in providers.tf. Module-level tags merge on top of these.
  common_tags = {
    Project     = var.project
    Environment = var.env
    ManagedBy   = "terraform"
    Repository  = "github.com/${var.github_org}/AWS-CoreStack-Blueprint"
  }
}

################################################################################
# APPLY ORDER — read before running terraform apply
#
# This project has a two-phase dependency: the security module creates IRSA
# roles that reference the EKS OIDC provider URL, but EKS needs the security
# module's IAM roles to exist first. Resolve with the following apply sequence:
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PHASE 1 — Foundation (oidc_provider_url = "" in terraform.tfvars)       │
# │                                                                          │
# │   terraform apply -target=module.networking \                            │
# │                   -target=module.security \                              │
# │                   -target=module.s3                                      │
# │                                                                          │
# │   Creates: VPC, subnets, SGs, KMS key, IAM roles (no IRSA),             │
# │            S3 buckets (no bucket policies yet)                           │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PHASE 2 — EKS cluster + OIDC provider                                   │
# │                                                                          │
# │   terraform apply -target=module.eks                                     │
# │                                                                          │
# │   Then extract the OIDC URL:                                             │
# │   terraform output -raw oidc_provider_url                               │
# │                                                                          │
# │   Set in terraform.tfvars:                                               │
# │   oidc_provider_url = "oidc.eks.eu-central-1.amazonaws.com/id/XXXX"     │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PHASE 3 — Security re-apply + S3 bucket policies                        │
# │                                                                          │
# │   terraform apply -target=module.security \                              │
# │                   -target=module.s3                                       │
# │                                                                          │
# │   Creates: IRSA trust policies, S3 bucket policies scoped to IRSA roles │
# └─────────────────────────────────────────────────────────────────────────┘
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │ PHASE 4 — Application layer (full apply)                                 │
# │                                                                          │
# │   terraform apply                                                        │
# │                                                                          │
# │   Creates: RDS, ALB, LGTM monitoring stack                               │
# └─────────────────────────────────────────────────────────────────────────┘
################################################################################

################################################################################
# Module: networking
# Layer 1 — must be applied first. All other modules consume its outputs.
################################################################################

module "networking" {
  source = "../../modules/networking"

  project            = var.project
  env                = var.env
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  single_nat_gateway = var.single_nat_gateway

  flow_log_retention_days = var.flow_log_retention_days

  tags = local.common_tags
}

################################################################################
# Module: security
# Layer 2 — depends on networking. Provides KMS, SGs, IAM roles, and IRSA.
#
# Two-phase inputs:
#   oidc_provider     : empty on Phase 1, filled after EKS apply in Phase 3
#   *_bucket_arn      : from s3 module (available after Phase 1)
#   private_route_table_ids : from networking (available after Phase 1)
################################################################################

module "security" {
  source = "../../modules/security"

  project    = var.project
  env        = var.env
  aws_region = var.aws_region
  tags       = local.common_tags

  # From networking module
  vpc_id                  = module.networking.vpc_id
  private_route_table_ids = module.networking.private_route_table_ids

  # EKS — cluster name needed for SG tags before EKS exists
  eks_cluster_name = local.cluster_name

  # OIDC — empty on first apply. Fill in terraform.tfvars after Phase 2,
  # then re-apply security (Phase 3) to create IRSA trust policies.
  oidc_provider = var.oidc_provider_url

  # S3 bucket ARNs for IRSA policy scoping — available after Phase 1 s3 apply.
  # Empty strings are safe: IRSA role resources are created but with no
  # resource restriction in the policy (defaults to "*").
  loki_bucket_arn  = module.s3.loki_bucket_arn
  mimir_bucket_arn = module.s3.mimir_bucket_arn
  tempo_bucket_arn = module.s3.tempo_bucket_arn
}

################################################################################
# Module: s3
# Layer 2 — parallel with security. Provides buckets for state, app, and LGTM.
#
# Two-phase inputs:
#   *_irsa_role_arn  : empty on Phase 1, filled from security outputs in Phase 3
#   s3_vpc_endpoint_id : always available after security Phase 1 apply
################################################################################

module "s3" {
  source = "../../modules/s3"

  project    = var.project
  env        = var.env
  tags       = local.common_tags

  # From security module — always available after Phase 1
  kms_key_arn = module.security.kms_key_arn

  # Observability retention periods — align with S3 lifecycle rules
  loki_retention_days  = var.loki_retention_days
  mimir_retention_days = var.mimir_retention_days
  tempo_retention_days = var.tempo_retention_days

  # VPC endpoint — available after security Phase 1 apply
  s3_vpc_endpoint_id = module.security.vpc_endpoint_s3_id

  # IRSA role ARNs — gates bucket policy creation. Empty on Phase 1 (no
  # policies created). Populated from security module after Phase 3 apply.
  loki_irsa_role_arn  = module.security.irsa_loki_role_arn
  mimir_irsa_role_arn = module.security.irsa_mimir_role_arn
  tempo_irsa_role_arn = module.security.irsa_tempo_role_arn
}

################################################################################
# Module: eks
# Layer 3 — depends on networking + security. Outputs OIDC provider URL
# needed for Phase 3 security re-apply.
################################################################################

module "eks" {
  source = "../../modules/eks"

  project    = var.project
  env        = var.env
  tags       = local.common_tags

  # Cluster identity
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # From networking module
  private_subnet_ids = module.networking.private_subnet_ids
  public_subnet_ids  = module.networking.public_subnet_ids

  # From security module
  eks_cluster_role_arn = module.security.eks_cluster_role_arn
  eks_node_role_arn    = module.security.eks_node_role_arn
  sg_control_plane_id  = module.security.sg_eks_control_plane_id
  kms_key_arn          = module.security.kms_key_arn

  # API endpoint access — tighten public_access_cidrs to your IP in prod
  enable_public_endpoint = var.enable_public_eks_endpoint
  public_access_cidrs    = var.eks_public_access_cidrs

  # Node group sizing
  node_group_name     = var.node_group_name
  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_disk_size_gb   = var.node_disk_size_gb

  # Control plane log retention
  control_plane_log_retention_days = var.control_plane_log_retention_days

  # CI/CD role — grants GitHub Actions cluster-admin access for deployments
  cicd_role_arn = var.cicd_role_arn
}

################################################################################
# Module: rds
# Layer 4 — depends on networking + security. Creates Multi-AZ PostgreSQL.
################################################################################

module "rds" {
  source = "../../modules/rds"

  project    = var.project
  env        = var.env
  tags       = local.common_tags

  # From networking module
  database_subnet_ids = module.networking.database_subnet_ids

  # From security module
  sg_rds_id   = module.security.sg_rds_id
  kms_key_arn = module.security.kms_key_arn

  # Engine
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  # Storage
  allocated_storage_gb     = var.rds_allocated_storage_gb
  max_allocated_storage_gb = var.rds_max_allocated_storage_gb

  # Credentials
  db_name     = var.db_name
  db_username = var.db_username

  # HA and backups
  multi_az              = var.rds_multi_az
  backup_retention_days = var.rds_backup_retention_days

  # Monitoring
  performance_insights_retention_days = var.rds_pi_retention_days
  slow_query_threshold_ms             = var.rds_slow_query_threshold_ms
  alarm_email                         = var.alarm_email
  alarm_connections_threshold         = var.rds_alarm_connections_threshold
}

################################################################################
# Module: alb
# Layer 4 — depends on networking + security + s3. Creates internet-facing ALB.
################################################################################

module "alb" {
  source = "../../modules/alb"

  project    = var.project
  env        = var.env
  tags       = local.common_tags

  # From networking module
  vpc_id             = module.networking.vpc_id
  public_subnet_ids  = module.networking.public_subnet_ids

  # From security module
  sg_alb_id = module.security.sg_alb_id

  # From s3 module — ALB writes access logs here
  access_logs_bucket_id = module.s3.access_logs_bucket_id

  # TLS and DNS
  domain_name        = var.domain_name
  create_dns_records = var.create_dns_records
  health_check_path  = var.health_check_path

  # Optional WAF association — leave empty until WAF WebACL is created
  waf_acl_arn = var.waf_acl_arn

  # Alerting
  alarm_email = var.alarm_email
}

################################################################################
# Module: monitoring
# Layer 5 — depends on EKS (Helm/K8s providers), security (KMS + IRSA), s3.
# Applied last — requires all other modules to be stable first.
################################################################################

module "monitoring" {
  source = "../../modules/monitoring"

  project    = var.project
  env        = var.env
  aws_region = var.aws_region
  tags       = local.common_tags

  # Domain for Grafana root_url
  domain_name = var.domain_name

  # From security module
  kms_key_arn = module.security.kms_key_arn

  # S3 bucket names (IDs) for LGTM storage backends
  loki_bucket_name  = module.s3.loki_bucket_id
  mimir_bucket_name = module.s3.mimir_bucket_id
  tempo_bucket_name = module.s3.tempo_bucket_id

  # IRSA role ARNs for LGTM S3 access (available after Phase 3)
  irsa_loki_role_arn  = module.security.irsa_loki_role_arn
  irsa_mimir_role_arn = module.security.irsa_mimir_role_arn
  irsa_tempo_role_arn = module.security.irsa_tempo_role_arn

  # Grafana credentials — read from Secrets Manager, not hardcoded
  grafana_admin_password = var.grafana_admin_password

  # Chart versions — pin explicitly, update in dedicated PRs
  loki_chart_version             = var.loki_chart_version
  alloy_chart_version            = var.alloy_chart_version
  mimir_chart_version            = var.mimir_chart_version
  tempo_chart_version            = var.tempo_chart_version
  prometheus_stack_chart_version = var.prometheus_stack_chart_version

  # Loki sizing
  loki_write_replicas  = var.loki_write_replicas
  loki_read_replicas   = var.loki_read_replicas
  loki_retention_hours = var.loki_retention_hours

  # Tempo sizing
  tempo_retention_hours = var.tempo_retention_hours
}
