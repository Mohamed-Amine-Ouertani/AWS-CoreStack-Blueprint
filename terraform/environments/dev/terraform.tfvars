################################################################################
# terraform.tfvars.example
#
# Copy this file to terraform.tfvars and fill in your values.
# terraform.tfvars is gitignored — never commit it.
#
#   cp terraform.tfvars.example terraform.tfvars
#
# Variables marked REQUIRED have no default and must be set before applying.
# Variables marked PHASE 2 should be left empty on first apply and filled
# after the EKS cluster is created (see main.tf apply order comments).
################################################################################

################################################################################
# Core identity
################################################################################

project    = "corestack"
env        = "dev"
aws_region = "eu-central-1"

# REQUIRED — your GitHub username or organisation
github_org = "your-github-username"

################################################################################
# Networking
################################################################################

vpc_cidr           = "10.0.0.0/16"
availability_zones = ["eu-central-1a", "eu-central-1b"]

# true saves ~$32/month in dev by sharing one NAT GW. Set false in prod.
single_nat_gateway = true

flow_log_retention_days = 30

################################################################################
# Two-phase apply — OIDC provider
#
# PHASE 2: After running `terraform apply -target=module.eks`, run:
#   terraform output -raw oidc_provider_url
# Paste the result below, then re-apply.
################################################################################

oidc_provider_url = ""   # Fill after Phase 2 eks apply

################################################################################
# EKS
################################################################################

kubernetes_version               = "1.30"
control_plane_log_retention_days = 90

# true = API reachable from internet (dev default for local kubectl)
# false = API only reachable from VPC (prod — requires VPN or bastion)
enable_public_eks_endpoint = true
eks_public_access_cidrs    = ["0.0.0.0/0"]   # Tighten to your IP in prod

# Node group
node_group_name     = "general"
node_instance_types = ["t3.medium", "t3a.medium"]
node_capacity_type  = "ON_DEMAND"
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 6
node_disk_size_gb   = 50

# GitHub Actions CI/CD role — leave empty until the role exists
# cicd_role_arn = "arn:aws:iam::123456789012:role/github-actions-corestack"
cicd_role_arn = ""

################################################################################
# RDS
################################################################################

rds_engine_version           = "15.7"
rds_instance_class           = "db.t3.micro"   # Upgrade to db.t3.medium for prod
rds_allocated_storage_gb     = 20
rds_max_allocated_storage_gb = 100

db_name     = "appdb"
db_username = "dbadmin"

# false in dev saves ~$45/month. Always true in prod.
rds_multi_az              = false
rds_backup_retention_days = 7

rds_pi_retention_days           = 31     # 7 = free tier, 31 = recommended
rds_slow_query_threshold_ms     = 1000   # Lower to 200 once baseline is established
rds_alarm_connections_threshold = 80     # ~80% of max_connections for db.t3.micro

################################################################################
# ALB and DNS
################################################################################

# REQUIRED — your domain name (must be in Route53 if create_dns_records = true)
domain_name        = "example.com"
create_dns_records = true
health_check_path  = "/healthz"

# Leave empty until WAF WebACL is created separately
waf_acl_arn = ""

################################################################################
# Observability — S3 retention
################################################################################

loki_retention_days  = 90
mimir_retention_days = 365
tempo_retention_days = 30

################################################################################
# Observability — Helm chart versions
# Pin these explicitly. Update in a dedicated PR to control upgrade timing.
################################################################################

loki_chart_version             = "6.6.2"
alloy_chart_version            = "0.4.0"
mimir_chart_version            = "5.3.0"
tempo_chart_version            = "1.10.1"
prometheus_stack_chart_version = "60.3.0"

################################################################################
# Observability — component sizing (dev defaults — scale up for prod)
################################################################################

loki_write_replicas   = 1
loki_read_replicas    = 1
loki_retention_hours  = 2160   # 90 days × 24 — must match loki_retention_days
tempo_retention_hours = 720    # 30 days × 24 — must match tempo_retention_days

################################################################################
# Grafana
#
# Do not hardcode this value. Set it from Secrets Manager before applying:
#
#   export TF_VAR_grafana_admin_password=$(aws secretsmanager get-secret-value \
#     --secret-id corestack/dev/grafana/admin \
#     --query SecretString --output text)
#
# Or store it in a .env file and source it before running terraform.
################################################################################

# grafana_admin_password is set via TF_VAR_grafana_admin_password env var
# Do not uncomment and hardcode here.

################################################################################
# Alerting
################################################################################

# Set to receive CloudWatch alarm emails for RDS and ALB
alarm_email = ""   # e.g. "ops@yourdomain.com"
