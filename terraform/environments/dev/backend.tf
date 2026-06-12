################################################################################
# Remote State — S3 + DynamoDB
#
# The S3 bucket and DynamoDB lock table referenced here are created by the
# bootstrap script (scripts/bootstrap.sh) before any terraform init is run.
# They are NOT managed by this state — they are pre-existing infrastructure.
#
# Run bootstrap first:
#   ./scripts/bootstrap.sh --env dev --region eu-central-1
#
# Key layout in the state bucket:
#   <project>/dev/terraform.tfstate     ← this environment
#   <project>/prod/terraform.tfstate    ← prod environment (separate apply)
#
# All environments share one state bucket. Isolation is via key prefix, not
# separate buckets — this simplifies IAM and avoids per-env bootstrap steps.
################################################################################

terraform {
  backend "s3" {
    bucket         = "corestack-tfstate-<ACCOUNT_ID>"   # Replace with your account ID
    key            = "corestack/dev/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    kms_key_id     = "alias/corestack-dev"              # Matches security module KMS alias
    dynamodb_table = "corestack-tfstate-lock"

    # Prevent accidental state deletion during terraform operations
    # This is separate from S3 bucket versioning (which handles recovery)
  }
}
