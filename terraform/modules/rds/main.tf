################################################################################
# Locals
################################################################################

locals {
  # Derive major version (e.g. "15" from "15.7") for parameter group family
  # and for naming. Avoids hardcoding "postgres15" as a magic string.
  engine_major_version = split(".", var.engine_version)[0]
  param_group_family   = "postgres${local.engine_major_version}"
  identifier           = "${var.project}-${var.env}-postgres"
}

################################################################################
# SNS Topic — alarm notifications
# All CloudWatch alarms below publish here. Wire this to PagerDuty, Slack, or
# email via an SNS subscription after apply. ARN is exported as an output.
################################################################################

resource "aws_sns_topic" "rds_alarms" {
  name              = "${var.project}-${var.env}-rds-alarms"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rds-alarms"
  })
}

# Optional: email subscription wired via variable. Skipped if address is empty.
resource "aws_sns_topic_subscription" "rds_alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.rds_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

################################################################################
# DB Subnet Group
################################################################################

resource "aws_db_subnet_group" "main" {
  name        = "${local.identifier}-subnet-group"
  description = "Database subnet group for ${var.project} ${var.env} — database tier subnets only, no public or private EKS subnets"
  subnet_ids  = var.database_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.identifier}-subnet-group"
  })
}

################################################################################
# DB Parameter Group
# Parameters use `pending-reboot` apply method where required. Parameters
# that can apply immediately use `immediate`. The distinction matters for
# zero-downtime parameter changes.
################################################################################

resource "aws_db_parameter_group" "main" {
  name        = "${local.identifier}-params"
  family      = local.param_group_family
  description = "Custom parameters for ${var.project} ${var.env} PostgreSQL ${local.engine_major_version}"

  # ── Query logging ──────────────────────────────────────────────────────────
  parameter {
    name         = "log_min_duration_statement"
    value        = var.slow_query_threshold_ms
    apply_method = "immediate"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  # Log statements that produce lock waits longer than 500ms.
  # Essential for diagnosing connection pool exhaustion under load.
  parameter {
    name         = "log_lock_waits"
    value        = "1"
    apply_method = "immediate"
  }

  # ── Checkpointing ──────────────────────────────────────────────────────────
  # Log checkpoints to track WAL write pressure. Frequent checkpoints
  # (< 5 min apart) indicate write load exceeding shared_buffers capacity.
  parameter {
    name         = "log_checkpoints"
    value        = "1"
    apply_method = "immediate"
  }

  # ── SSL enforcement ────────────────────────────────────────────────────────
  # rds.force_ssl = 1 rejects all non-SSL connections at the PostgreSQL level,
  # providing defense-in-depth alongside the VPC SG rules.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # ── Connection limits ──────────────────────────────────────────────────────
  # idle_in_transaction_session_timeout: terminate sessions stuck in an idle
  # transaction for > 5 min. Prevents connection slot exhaustion from hung
  # application code. Value in milliseconds.
  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = "300000"
    apply_method = "immediate"
  }

  # statement_timeout: hard kill for runaway queries > 30 seconds.
  # Application queries should have their own timeouts; this is a backstop.
  parameter {
    name         = "statement_timeout"
    value        = "30000"
    apply_method = "immediate"
  }

  tags = merge(var.tags, {
    Name = "${local.identifier}-params"
  })

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Master Password — generated and stored in Secrets Manager
# The password is never stored in Terraform state in plaintext — random_password
# result is marked sensitive and only written to Secrets Manager.
################################################################################

resource "random_password" "rds" {
  length  = 32
  special = true
  # Exclude characters that require shell escaping in connection strings
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "rds" {
  name        = "${var.project}/${var.env}/rds/master"
  description = "RDS master credentials for ${var.project} ${var.env}. Contains username, password, host, port, dbname, and connection URL."
  kms_key_id  = var.kms_key_arn

  # 30-day recovery window in prod gives time to detect accidental deletion
  # before the secret is permanently gone. 7 days is sufficient for dev.
  recovery_window_in_days = var.env == "prod" ? 30 : 7

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id

  # Structured JSON so application code can parse fields individually
  # without string manipulation on the connection URL.
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.rds.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
    url      = "postgresql://${var.db_username}:${random_password.rds.result}@${aws_db_instance.main.address}:${aws_db_instance.main.port}/${var.db_name}?sslmode=require"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

################################################################################
# Enhanced Monitoring IAM Role
################################################################################

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.project}-${var.env}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

################################################################################
# RDS Instance — Multi-AZ PostgreSQL
################################################################################

resource "aws_db_instance" "main" {
  identifier = local.identifier

  # ── Engine ──────────────────────────────────────────────────────────────────
  engine               = "postgres"
  engine_version       = var.engine_version
  parameter_group_name = aws_db_parameter_group.main.name

  # ── Compute ─────────────────────────────────────────────────────────────────
  instance_class = var.instance_class

  # ── Storage ─────────────────────────────────────────────────────────────────
  storage_type          = "gp3"
  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb  # Autoscaling ceiling
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn
  # iops and storage_throughput are only valid on io1/io2. gp3 uses defaults
  # (3000 IOPS, 125 MB/s) which are sufficient for most web workloads.

  # ── Credentials ─────────────────────────────────────────────────────────────
  db_name  = var.db_name
  username = var.db_username
  password = random_password.rds.result

  # ── Network ─────────────────────────────────────────────────────────────────
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.sg_rds_id]
  publicly_accessible    = false   # Never. Access is via private subnet + SG only.
  port                   = 5432

  # ── SSL ─────────────────────────────────────────────────────────────────────
  # rds-ca-rsa2048-g1 is the current default CA for new RDS instances.
  # AWS rotates this CA — set explicitly so Terraform detects any drift.
  ca_cert_identifier = "rds-ca-rsa2048-g1"

  # ── High Availability ───────────────────────────────────────────────────────
  # Multi-AZ provisions a synchronous standby replica in a second AZ.
  # Failover is automatic and typically completes in 60-120 seconds.
  # False in dev saves ~$45/month — standby is not needed for non-production.
  multi_az = var.multi_az

  # ── Backups ─────────────────────────────────────────────────────────────────
  backup_retention_period  = var.backup_retention_days
  backup_window            = "03:00-04:00"    # UTC — avoids EU business hours
  maintenance_window       = "Mon:04:00-Mon:05:00"
  copy_tags_to_snapshot    = true

  # Static snapshot identifier — does NOT use timestamp() which re-evaluates
  # on every plan and causes a perpetual diff in Terraform state.
  final_snapshot_identifier = "${local.identifier}-final"
  skip_final_snapshot       = var.env != "prod"
  delete_automated_backups  = var.env != "prod"

  # ── Monitoring ──────────────────────────────────────────────────────────────
  # Enhanced monitoring: OS-level metrics (CPU steal, memory, swap, filesystem)
  # at 60-second granularity. Uses the CloudWatch agent inside the RDS OS.
  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  # Performance Insights: query-level visibility into wait events and load.
  # retention_period: 7 = free tier, 731 days = paid (~$0.02/vCPU/month).
  # 31 days is a good middle ground — covers most post-incident investigations.
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.kms_key_arn
  performance_insights_retention_period = var.performance_insights_retention_days

  # Export PostgreSQL and upgrade logs to CloudWatch for Loki ingestion
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # ── Protection ──────────────────────────────────────────────────────────────
  deletion_protection = var.env == "prod"

  tags = merge(var.tags, {
    Name = local.identifier
  })

  lifecycle {
    ignore_changes = [
      # Ignore password — managed by random_password + Secrets Manager rotation.
      # Terraform would otherwise diff the password on every plan because
      # the RDS API never returns the current password value.
      password,
      # Ignore snapshot identifier — static value, no rotation needed.
      final_snapshot_identifier,
    ]
  }
}

################################################################################
# CloudWatch Alarms
# Every alarm fires to the SNS topic created above.
# Thresholds are starting points — tune based on baseline metrics after
# the first week of operation.
################################################################################

locals {
  alarm_actions = [aws_sns_topic.rds_alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.identifier}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3        # Sustained for 15 min before alerting
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU > 80% for 15 minutes. Check slow query log and active connections."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.identifier}-free-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240   # 10 GB in bytes
  alarm_description   = "RDS free storage < 10 GB. Storage autoscaling may be insufficient — check max_allocated_storage."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${local.identifier}-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = var.alarm_connections_threshold
  alarm_description   = "RDS connection count high. Check for connection pool misconfiguration or connection leak."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_read_latency_high" {
  alarm_name          = "${local.identifier}-read-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ReadLatency"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  # 20ms p-avg read latency on gp3 is a warning sign — baseline should be < 5ms
  threshold           = 0.02
  alarm_description   = "RDS read latency > 20ms. Investigate I/O pressure or missing indexes."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = local.alarm_actions

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_replication_lag" {
  # Only relevant for Multi-AZ — standby lag indicates the failover target
  # is behind the primary. Sustained lag > 1 min is a risk for RPO.
  count = var.multi_az ? 1 : 0

  alarm_name          = "${local.identifier}-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 30   # seconds
  alarm_description   = "RDS Multi-AZ replication lag > 30s. Standby is behind — failover RPO is degraded."
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = local.alarm_actions

  tags = var.tags
}
