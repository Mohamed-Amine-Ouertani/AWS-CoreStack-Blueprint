################################################################################
# Locals — bucket definitions and shared configuration
#
# All observability buckets (loki, mimir, tempo) share the same base config:
# KMS encryption, versioning, public access block, ownership controls, and
# server access logging. Differences (lifecycle rules, retention) are handled
# per-bucket below. Using locals + for_each removes ~150 lines of repetition.
################################################################################

locals {
  # Observability buckets — iterated for shared config blocks
  obs_buckets = {
    loki  = "${var.project}-${var.env}-loki-${data.aws_caller_identity.current.account_id}"
    mimir = "${var.project}-${var.env}-mimir-${data.aws_caller_identity.current.account_id}"
    tempo = "${var.project}-${var.env}-tempo-${data.aws_caller_identity.current.account_id}"
  }

  obs_purposes = {
    loki  = "observability-logs"
    mimir = "observability-metrics"
    tempo = "observability-traces"
  }
}

data "aws_caller_identity" "current" {}

################################################################################
# Access Logging Bucket
# All other buckets ship their server access logs here.
# Kept separate and minimal — no versioning, simple lifecycle, no KMS
# (KMS on a log destination bucket causes a circular dependency since the
# logging service must decrypt to write, but the key policy isn't set yet).
################################################################################

resource "aws_s3_bucket" "access_logs" {
  bucket        = "${var.project}-${var.env}-s3-access-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.env != "prod"

  tags = merge(var.tags, {
    Name    = "${var.project}-${var.env}-s3-access-logs"
    Purpose = "s3-access-logging"
  })
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    # BucketOwnerPreferred required for access logging delivery
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (not KMS) avoids the circular dependency described above
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    expiration {
      days = 90
    }
  }
}

################################################################################
# Observability Buckets — Loki, Mimir, Tempo
# Created via for_each over locals.obs_buckets so all three share identical
# base configuration. Lifecycle rules are set individually below since each
# component has different retention requirements.
################################################################################

resource "aws_s3_bucket" "obs" {
  for_each = local.obs_buckets

  bucket        = each.value
  force_destroy = var.env != "prod"

  tags = merge(var.tags, {
    Name      = "${var.project}-${var.env}-${each.key}"
    Purpose   = local.obs_purposes[each.key]
    Component = each.key
  })
}

resource "aws_s3_bucket_ownership_controls" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.obs[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.obs[each.key].id

  versioning_configuration {
    # Versioning on observability buckets protects against accidental chunk deletion.
    # Noncurrent versions expire quickly (see lifecycle rules) to contain cost.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.obs[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # Bucket key reduces KMS API call volume by ~99% for high-throughput
    # observability writes. Each object no longer needs its own GenerateDataKey
    # call — the bucket-level key is cached and reused.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.obs[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "obs" {
  for_each = local.obs_buckets
  bucket   = aws_s3_bucket.obs[each.key].id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "${each.key}/"

  depends_on = [aws_s3_bucket_ownership_controls.access_logs]
}

# ── Lifecycle rules (per component) ─────────────────────────────────────────

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.obs["loki"].id

  rule {
    id     = "loki-chunk-retention"
    status = "Enabled"

    # Loki chunks are frequently accessed in the first 7 days (recent log queries),
    # rarely after 30. Standard-IA after 30 days, expire at retention threshold.
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.loki_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }

  depends_on = [aws_s3_bucket_versioning.obs]
}

resource "aws_s3_bucket_lifecycle_configuration" "mimir" {
  bucket = aws_s3_bucket.obs["mimir"].id

  rule {
    id     = "mimir-block-retention"
    status = "Enabled"

    # Mimir compacts blocks aggressively — recent blocks are hot, older blocks
    # (post-compaction) are cold. IA after 14 days matches Mimir's compaction schedule.
    transition {
      days          = 14
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.mimir_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 3
    }
  }

  depends_on = [aws_s3_bucket_versioning.obs]
}

resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.obs["tempo"].id

  rule {
    id     = "tempo-trace-retention"
    status = "Enabled"

    # Traces have the shortest useful lifespan — most debugging uses traces
    # from the last 7 days. IA after 7 days, expire at var.tempo_retention_days.
    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.tempo_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 2
    }
  }

  depends_on = [aws_s3_bucket_versioning.obs]
}

# ── Bucket policies (restrict to IRSA roles + VPC endpoint) ─────────────────
# Defense-in-depth: even if an IAM policy is misconfigured, the bucket policy
# blocks access from outside the VPC and from non-IRSA principals.
# Applied only when the respective IRSA role ARN is provided (avoids chicken-
# and-egg on first apply when IRSA roles don't exist yet).

resource "aws_s3_bucket_policy" "loki" {
  count  = var.loki_irsa_role_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.obs["loki"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonVpcAccess"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.obs["loki"].arn,
          "${aws_s3_bucket.obs["loki"].arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = var.s3_vpc_endpoint_id
          }
          # Exempt AWS services (e.g. lifecycle, replication) that don't use VPC endpoints
          ArnNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
              var.loki_irsa_role_arn
            ]
          }
        }
      },
      {
        Sid    = "AllowLokiIrsaRole"
        Effect = "Allow"
        Principal = {
          AWS = var.loki_irsa_role_arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.obs["loki"].arn,
          "${aws_s3_bucket.obs["loki"].arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "mimir" {
  count  = var.mimir_irsa_role_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.obs["mimir"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonVpcAccess"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.obs["mimir"].arn,
          "${aws_s3_bucket.obs["mimir"].arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = var.s3_vpc_endpoint_id
          }
          ArnNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
              var.mimir_irsa_role_arn
            ]
          }
        }
      },
      {
        Sid    = "AllowMimirIrsaRole"
        Effect = "Allow"
        Principal = {
          AWS = var.mimir_irsa_role_arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.obs["mimir"].arn,
          "${aws_s3_bucket.obs["mimir"].arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "tempo" {
  count  = var.tempo_irsa_role_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.obs["tempo"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonVpcAccess"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.obs["tempo"].arn,
          "${aws_s3_bucket.obs["tempo"].arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:SourceVpce" = var.s3_vpc_endpoint_id
          }
          ArnNotLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
              var.tempo_irsa_role_arn
            ]
          }
        }
      },
      {
        Sid    = "AllowTempoIrsaRole"
        Effect = "Allow"
        Principal = {
          AWS = var.tempo_irsa_role_arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          aws_s3_bucket.obs["tempo"].arn,
          "${aws_s3_bucket.obs["tempo"].arn}/*"
        ]
      }
    ]
  })
}

################################################################################
# Application Bucket
################################################################################

resource "aws_s3_bucket" "app" {
  bucket        = "${var.project}-${var.env}-app-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.env != "prod"

  tags = merge(var.tags, {
    Name    = "${var.project}-${var.env}-app"
    Purpose = "application"
  })
}

resource "aws_s3_bucket_ownership_controls" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "app" {
  bucket        = aws_s3_bucket.app.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "app/"

  depends_on = [aws_s3_bucket_ownership_controls.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    id     = "tiered-storage"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

################################################################################
# Terraform Remote State Bucket + DynamoDB Lock Table
#
# Intentionally NOT destroyed even in dev — state loss is unrecoverable.
# Kept in this module for co-location but managed with extra care:
# force_destroy = false always, separate from env-scoped buckets.
################################################################################

resource "aws_s3_bucket" "tfstate" {
  bucket        = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = merge(var.tags, {
    Name    = "${var.project}-tfstate"
    Purpose = "terraform-state"
    # State bucket is not env-scoped — one bucket holds all environments' state.
    # Environment isolation is done via key prefixes in backend.tf.
  })
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    # Versioning on state bucket is non-negotiable — it's the only way to
    # recover from a corrupted or accidentally deleted state file.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "tfstate" {
  bucket        = aws_s3_bucket.tfstate.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "tfstate/"

  depends_on = [aws_s3_bucket_ownership_controls.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "noncurrent-state-retention"
    status = "Enabled"

    # Keep old state versions for 90 days — enough to recover from any bad apply.
    # State files are tiny so cost is negligible.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyInsecureTransport"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid    = "DenyStateDelete"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:DeleteObject"
        Resource  = "${aws_s3_bucket.tfstate.arn}/*"
        Condition = {
          # Only root can delete state objects — blocks accidental pipeline deletions
          ArnNotEquals = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
        }
      }
    ]
  })
}

# DynamoDB table for Terraform state locking
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "${var.project}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = merge(var.tags, {
    Name    = "${var.project}-tfstate-lock"
    Purpose = "terraform-state-lock"
  })
}
