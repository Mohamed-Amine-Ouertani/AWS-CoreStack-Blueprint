################################################################################
# Connection details — sensitive, consumed by application and monitoring layers
################################################################################

output "db_endpoint" {
  description = "RDS instance endpoint (hostname only). Used in application config and Grafana datasource. Do not construct connection strings from this alone — use secret_arn."
  value       = aws_db_instance.main.address
  sensitive   = true
}

output "db_port" {
  description = "Database port (5432 for PostgreSQL)."
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Name of the initial database created on the instance."
  value       = aws_db_instance.main.db_name
}

output "db_identifier" {
  description = "RDS instance identifier. Used in CloudWatch dashboards and enhanced monitoring console."
  value       = aws_db_instance.main.identifier
}

output "db_arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.main.arn
}

################################################################################
# Secrets Manager — primary way applications should retrieve credentials
################################################################################

output "secret_arn" {
  description = <<-EOT
    Secrets Manager secret ARN containing full connection details as JSON:
    { username, password, host, port, dbname, url }
    Applications should read this secret at startup rather than receiving
    connection details as environment variables.
  EOT
  value = aws_secretsmanager_secret.rds.arn
}

output "secret_name" {
  description = "Secrets Manager secret name. Used in ESO ExternalSecret manifests in Project C."
  value       = aws_secretsmanager_secret.rds.name
}

################################################################################
# Monitoring
################################################################################

output "alarm_sns_topic_arn" {
  description = "SNS topic ARN for RDS CloudWatch alarms. Wire additional subscriptions (PagerDuty, Slack) externally after apply."
  value       = aws_sns_topic.rds_alarms.arn
}

output "enhanced_monitoring_role_arn" {
  description = "IAM role ARN for RDS Enhanced Monitoring."
  value       = aws_iam_role.rds_enhanced_monitoring.arn
}

################################################################################
# Resource identifiers for Grafana dashboards
################################################################################

output "parameter_group_name" {
  description = "DB parameter group name. Reference when updating parameters without recreating the instance."
  value       = aws_db_parameter_group.main.name
}

output "subnet_group_name" {
  description = "DB subnet group name."
  value       = aws_db_subnet_group.main.name
}
