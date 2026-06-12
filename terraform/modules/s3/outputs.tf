################################################################################
# Application bucket
################################################################################

output "app_bucket_id" {
  description = "Name of the application S3 bucket"
  value       = aws_s3_bucket.app.id
}

output "app_bucket_arn" {
  description = "ARN of the application S3 bucket"
  value       = aws_s3_bucket.app.arn
}

################################################################################
# Observability buckets — ARNs fed into security module IRSA policies
################################################################################

output "loki_bucket_id" {
  description = "Name of the Loki log storage bucket"
  value       = aws_s3_bucket.obs["loki"].id
}

output "loki_bucket_arn" {
  description = "ARN of the Loki log storage bucket. Passed to security module for IRSA policy scoping."
  value       = aws_s3_bucket.obs["loki"].arn
}

output "mimir_bucket_id" {
  description = "Name of the Mimir metrics storage bucket"
  value       = aws_s3_bucket.obs["mimir"].id
}

output "mimir_bucket_arn" {
  description = "ARN of the Mimir metrics storage bucket. Passed to security module for IRSA policy scoping."
  value       = aws_s3_bucket.obs["mimir"].arn
}

output "tempo_bucket_id" {
  description = "Name of the Tempo trace storage bucket"
  value       = aws_s3_bucket.obs["tempo"].id
}

output "tempo_bucket_arn" {
  description = "ARN of the Tempo trace storage bucket. Passed to security module for IRSA policy scoping."
  value       = aws_s3_bucket.obs["tempo"].arn
}

################################################################################
# Terraform state
################################################################################

output "tfstate_bucket_id" {
  description = "Name of the Terraform remote state bucket"
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_bucket_arn" {
  description = "ARN of the Terraform remote state bucket"
  value       = aws_s3_bucket.tfstate.arn
}

output "tfstate_lock_table_name" {
  description = "DynamoDB table name for Terraform state locking"
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "tfstate_lock_table_arn" {
  description = "DynamoDB table ARN for Terraform state locking. Used in CI/CD role policies to allow lock acquisition."
  value       = aws_dynamodb_table.tfstate_lock.arn
}

################################################################################
# Access logging
################################################################################

output "access_logs_bucket_id" {
  description = "Name of the S3 server access logs bucket"
  value       = aws_s3_bucket.access_logs.id
}
