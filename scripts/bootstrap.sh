#!/usr/bin/env bash
################################################################################
# bootstrap.sh
#
# Creates the S3 remote state bucket and DynamoDB lock table that Terraform
# needs before `terraform init` can run. Run this once per AWS account.
#
# Usage:
#   ./scripts/bootstrap.sh --env dev --region eu-central-1
#   ./scripts/bootstrap.sh --env prod --region eu-central-1
#
# Prerequisites:
#   - AWS CLI >= 2.x configured with a profile that has S3 + DynamoDB + KMS
#     permissions in the target account
#   - The AWS_PROFILE or AWS_ACCESS_KEY_ID env var set
#
# What it creates:
#   S3 bucket   : <project>-tfstate-<account-id>
#   DynamoDB    : <project>-tfstate-lock
#   Both are shared across all environments — isolation is via state key prefix.
################################################################################

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROJECT="corestack"
REGION="eu-central-1"
ENV=""

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 --env <dev|staging|prod> [--region <aws-region>] [--project <name>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)     ENV="$2";     shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    *)         usage ;;
  esac
done

[[ -z "$ENV" ]] && { echo "ERROR: --env is required"; usage; }
[[ "$ENV" =~ ^(dev|staging|prod)$ ]] || { echo "ERROR: env must be dev, staging, or prod"; exit 1; }

# ── Resolve account ID ────────────────────────────────────────────────────────
echo "→ Resolving AWS account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: ${ACCOUNT_ID}"
echo "  Region:  ${REGION}"
echo "  Project: ${PROJECT}"
echo "  Env:     ${ENV}"
echo ""

BUCKET_NAME="${PROJECT}-tfstate-${ACCOUNT_ID}"
TABLE_NAME="${PROJECT}-tfstate-lock"

# ── S3 state bucket ───────────────────────────────────────────────────────────
echo "→ Checking S3 state bucket: ${BUCKET_NAME}"

if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "  Already exists — skipping creation"
else
  echo "  Creating..."

  if [[ "${REGION}" == "us-east-1" ]]; then
    # us-east-1 does not accept a LocationConstraint — different API call
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  echo "  Enabling versioning..."
  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  echo "  Enabling server-side encryption (SSE-S3)..."
  # Using SSE-S3 not KMS here — the KMS key doesn't exist yet (Terraform creates it).
  # After the first Terraform apply, the bucket can be migrated to KMS encryption
  # via a targeted apply on the s3 module.
  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }'

  echo "  Blocking public access..."
  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "  Enforcing TLS-only access..."
  aws s3api put-bucket-policy \
    --bucket "${BUCKET_NAME}" \
    --policy "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"DenyInsecureTransport\",
        \"Effect\": \"Deny\",
        \"Principal\": \"*\",
        \"Action\": \"s3:*\",
        \"Resource\": [
          \"arn:aws:s3:::${BUCKET_NAME}\",
          \"arn:aws:s3:::${BUCKET_NAME}/*\"
        ],
        \"Condition\": {
          \"Bool\": { \"aws:SecureTransport\": \"false\" }
        }
      }]
    }"

  echo "  ✓ S3 bucket created: ${BUCKET_NAME}"
fi

# ── DynamoDB lock table ───────────────────────────────────────────────────────
echo ""
echo "→ Checking DynamoDB lock table: ${TABLE_NAME}"

if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "  Already exists — skipping creation"
else
  echo "  Creating..."
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "  Waiting for table to become active..."
  aws dynamodb wait table-exists \
    --table-name "${TABLE_NAME}" \
    --region "${REGION}"

  echo "  Enabling point-in-time recovery..."
  aws dynamodb update-continuous-backups \
    --table-name "${TABLE_NAME}" \
    --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true \
    --region "${REGION}"

  echo "  ✓ DynamoDB table created: ${TABLE_NAME}"
fi

# ── Print backend config ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Bootstrap complete. Update backend.tf with these values:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  terraform {"
echo "    backend \"s3\" {"
echo "      bucket         = \"${BUCKET_NAME}\""
echo "      key            = \"${PROJECT}/${ENV}/terraform.tfstate\""
echo "      region         = \"${REGION}\""
echo "      encrypt        = true"
echo "      dynamodb_table = \"${TABLE_NAME}\""
echo "    }"
echo "  }"
echo ""
echo "  Then run:"
echo "    cd terraform/environments/${ENV}"
echo "    terraform init"
echo ""
