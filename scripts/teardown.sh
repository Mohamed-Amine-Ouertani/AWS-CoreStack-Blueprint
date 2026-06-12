#!/usr/bin/env bash
################################################################################
# teardown.sh
#
# Destroys the environment in the correct order to avoid dependency errors.
# Terraform's dependency graph handles most ordering, but a few resources
# require explicit sequencing:
#
#   1. monitoring  — Helm releases must be removed before EKS node groups drain
#   2. alb         — ALB must be removed before the security group it references
#   3. rds         — final snapshot must complete before subnet group is removed
#   4. eks         — node groups must drain before VPC ENIs are released
#   5. s3          — bucket policies reference IRSA roles; remove policies first
#   6. security    — IAM roles after all resources that reference them
#   7. networking  — VPC last; all ENIs must be released first
#
# Usage:
#   ./scripts/teardown.sh --env dev --region eu-central-1
#
# WARNING: This script destroys real infrastructure. It will prompt for
# confirmation before proceeding. It will NOT destroy the tfstate bucket
# or DynamoDB lock table — those are managed outside Terraform.
#
# The --force flag skips confirmation. Use only in CI with extreme care.
################################################################################

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
ENV=""
REGION="eu-central-1"
FORCE=false

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 --env <dev|staging|prod> [--region <region>] [--force]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    ENV="$2";    shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --force)  FORCE=true;  shift   ;;
    *)        usage ;;
  esac
done

[[ -z "$ENV" ]] && { echo "ERROR: --env is required"; usage; }
[[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { echo "ERROR: env must be dev, staging, or prod"; exit 1; }

ENV_DIR="$(cd "$(dirname "$0")/.." && pwd)/terraform/environments/${ENV}"
[[ -d "$ENV_DIR" ]] || { echo "ERROR: Directory not found: ${ENV_DIR}"; exit 1; }

# ── Confirmation gate ─────────────────────────────────────────────────────────
if [[ "$FORCE" != "true" ]]; then
  echo ""
  echo "  ┌─────────────────────────────────────────────────┐"
  echo "  │  WARNING: This will destroy the ${ENV} environment  │"
  echo "  │  Region: ${REGION}                                    │"
  echo "  │  This action cannot be undone.                   │"
  echo "  └─────────────────────────────────────────────────┘"
  echo ""
  read -r -p "  Type the environment name to confirm: " CONFIRM
  [[ "$CONFIRM" == "$ENV" ]] || { echo "Aborted."; exit 1; }
fi

cd "$ENV_DIR"

# ── Helper function ───────────────────────────────────────────────────────────
destroy_target() {
  local module="$1"
  echo ""
  echo "→ Destroying module.${module}..."
  terraform destroy \
    -target="module.${module}" \
    -auto-approve \
    -input=false
  echo "  ✓ module.${module} destroyed"
}

# ── Init (required to use targets) ───────────────────────────────────────────
echo "→ Initialising Terraform..."
terraform init -input=false -reconfigure

# ── Ordered destroy ───────────────────────────────────────────────────────────
# monitoring first — removes Helm releases before EKS node groups are touched
destroy_target "monitoring"

# alb before security — ALB holds references to the sg_alb security group
destroy_target "alb"

# rds before networking — RDS must release its ENIs before subnet groups go
destroy_target "rds"

# eks — drains node groups, removes OIDC provider and access entries
destroy_target "eks"

# s3 — bucket policies reference IRSA roles; safe to remove after EKS
destroy_target "s3"

# security — IAM roles, KMS key, VPC endpoint, security groups
destroy_target "security"

# networking last — VPC, subnets, NAT GWs, IGW
destroy_target "networking"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Teardown complete for environment: ${ENV}"
echo ""
echo "  NOTE: The following were NOT destroyed (managed outside TF):"
echo "    - S3 tfstate bucket (contains state history)"
echo "    - DynamoDB lock table"
echo ""
echo "  To remove those manually:"
echo "    aws s3 rb s3://<project>-tfstate-<account-id> --force"
echo "    aws dynamodb delete-table --table-name <project>-tfstate-lock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
