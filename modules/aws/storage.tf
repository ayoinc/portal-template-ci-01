locals {
  # Every bucket of the stack, by role: the general storage bucket and the two
  # data-lake buckets. All of them are private, versioned, encrypted and
  # TLS-only; they differ in their lifecycle rules only.
  buckets = toset(concat(
    var.enable_storage ? ["storage"] : [],
    local.create_data_lake ? ["raw", "curated"] : [],
  ))

  lifecycle_rules = {
    # Applied when cost optimisation is on.
    storage = {
      storage_class   = "INTELLIGENT_TIERING"
      transition_days = 30
      archive_class   = null
      archive_days    = null
    }
    # Raw data is read while it is fresh, then kept cheaply.
    raw = {
      storage_class   = "STANDARD_IA"
      transition_days = 30
      archive_class   = "GLACIER_IR"
      archive_days    = 90
    }
    # Curated data has no fixed access pattern.
    curated = {
      storage_class   = "INTELLIGENT_TIERING"
      transition_days = 30
      archive_class   = null
      archive_days    = null
    }
  }

  bucket_lifecycles = {
    for role in local.buckets : role => local.lifecycle_rules[role]
    if role != "storage" || var.enable_cost_optimization
  }

  replicated_buckets = var.enable_disaster_recovery ? local.buckets : toset([])

  sse_algorithm = var.enable_kms ? "aws:kms" : "AES256"

  # Bucket names are global: the random suffix keeps them unique.
  bucket_names         = { for role in keys(local.lifecycle_rules) : role => "${var.name_prefix}-${role}-${random_id.suffix.hex}" }
  replica_bucket_names = { for role in keys(local.lifecycle_rules) : role => "${var.name_prefix}-${role}-dr-${random_id.suffix.hex}" }

  # Request metrics feed the storage alarm and the dashboard.
  create_bucket_metrics = var.enable_monitoring || var.enable_alerting
  bucket_metric_filter  = "EntireBucket"
  replication_rule_id   = "disaster-recovery"
}

# -----------------------------------------------------------------------------
# Buckets
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = local.bucket_names[each.key]
  force_destroy = !var.require_deletion_protection

  tags = merge(var.tags, local.storage_backup_tag)
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    bucket_key_enabled = var.enable_kms

    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = local.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.this[each.key].arn,
          "${aws_s3_bucket.this[each.key].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }],
      # Only the CDN distribution of this stack may read the storage bucket.
      each.key == "storage" && local.create_cdn ? [{
        Sid       = "AllowCloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.${local.dns_suffix}" }
        Action    = "s3:GetObject"
        Resource  = ["${aws_s3_bucket.this[each.key].arn}/*"]
        Condition = {
          StringEquals = { "aws:SourceArn" = aws_cloudfront_distribution.this[0].arn }
        }
      }] : [],
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.bucket_lifecycles

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    id     = "tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = each.value.transition_days
      storage_class = each.value.storage_class
    }

    dynamic "transition" {
      for_each = each.value.archive_class == null ? [] : [each.value]

      content {
        days          = transition.value.archive_days
        storage_class = transition.value.archive_class
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules for versions need versioning to be on.
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_metric" "this" {
  for_each = local.create_bucket_metrics ? local.buckets : toset([])

  bucket = aws_s3_bucket.this[each.key].id
  name   = local.bucket_metric_filter
}

# -----------------------------------------------------------------------------
# Cross-region replicas (disaster recovery)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "replica" {
  for_each = local.replicated_buckets

  region        = var.secondary_region
  bucket        = local.replica_bucket_names[each.key]
  force_destroy = !var.require_deletion_protection

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  rule {
    bucket_key_enabled = var.enable_kms

    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = local.secondary_kms_key_arn
    }
  }
}

resource "aws_s3_bucket_policy" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.replica[each.key].arn,
        "${aws_s3_bucket.replica[each.key].arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.replica]
}

# Old versions are not kept forever in the replica either.
resource "aws_s3_bucket_lifecycle_configuration" "replica" {
  for_each = local.replicated_buckets

  region = var.secondary_region
  bucket = aws_s3_bucket.replica[each.key].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.replica]
}

resource "aws_iam_role" "replication" {
  count = var.enable_disaster_recovery && length(local.buckets) > 0 ? 1 : 0

  name = "${var.name_prefix}-s3-replication"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "s3.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "replication" {
  count = var.enable_disaster_recovery && length(local.buckets) > 0 ? 1 : 0

  name = "replicate-buckets"
  role = aws_iam_role.replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadSourceConfiguration"
          Effect   = "Allow"
          Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
          Resource = [for role, bucket in aws_s3_bucket.this : bucket.arn]
        },
        {
          Sid    = "ReadSourceVersions"
          Effect = "Allow"
          Action = [
            "s3:GetObjectVersionForReplication",
            "s3:GetObjectVersionAcl",
            "s3:GetObjectVersionTagging",
          ]
          Resource = [for role, bucket in aws_s3_bucket.this : "${bucket.arn}/*"]
        },
        {
          Sid      = "WriteReplicas"
          Effect   = "Allow"
          Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
          Resource = [for role, bucket in aws_s3_bucket.replica : "${bucket.arn}/*"]
        },
      ],
      # The replication role decrypts with the primary key and encrypts the
      # replicas with the key of the disaster-recovery region.
      [for statement in [
        {
          Sid      = "DecryptSource"
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = [local.kms_key_arn]
          Condition = {
            StringEquals = { "kms:ViaService" = "s3.${var.region}.${local.dns_suffix}" }
          }
        },
        {
          Sid      = "EncryptReplicas"
          Effect   = "Allow"
          Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
          Resource = [local.secondary_kms_key_arn]
          Condition = {
            StringEquals = { "kms:ViaService" = "s3.${var.secondary_region}.${local.dns_suffix}" }
          }
        },
      ] : statement if var.enable_kms],
    )
  })
}

resource "aws_s3_bucket_replication_configuration" "this" {
  for_each = local.replicated_buckets

  bucket = aws_s3_bucket.this[each.key].id
  role   = aws_iam_role.replication[0].arn

  rule {
    id     = local.replication_rule_id
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    dynamic "source_selection_criteria" {
      for_each = var.enable_kms ? [1] : []

      content {
        sse_kms_encrypted_objects {
          status = "Enabled"
        }
      }
    }

    destination {
      bucket        = aws_s3_bucket.replica[each.key].arn
      storage_class = var.enable_cost_optimization ? "STANDARD_IA" : "STANDARD"

      dynamic "encryption_configuration" {
        for_each = var.enable_kms ? [local.secondary_kms_key_arn] : []

        content {
          replica_kms_key_id = encryption_configuration.value
        }
      }

      metrics {
        status = "Enabled"
      }
    }
  }

  # Replication needs versioning on both sides and the role's permissions.
  depends_on = [
    aws_s3_bucket_versioning.this,
    aws_s3_bucket_versioning.replica,
    aws_iam_role_policy.replication,
  ]
}
