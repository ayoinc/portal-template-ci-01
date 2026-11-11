locals {
  # Managed policies of the backup role. The S3 ones are needed only when the
  # buckets are part of the plan.
  backup_role_policies = concat(
    [
      "service-role/AWSBackupServiceRolePolicyForBackup",
      "service-role/AWSBackupServiceRolePolicyForRestores",
    ],
    var.enable_backup && length(local.buckets) > 0 ? [
      "AWSBackupServiceRolePolicyForS3Backup",
      "AWSBackupServiceRolePolicyForS3Restore",
    ] : [],
  )

  copy_backups = local.create_backup && var.enable_disaster_recovery
}

resource "aws_backup_vault" "this" {
  count = local.create_backup ? 1 : 0

  name          = var.name_prefix
  kms_key_arn   = local.kms_key_arn
  force_destroy = !var.require_deletion_protection

  tags = var.tags
}

# Governance-mode lock: recovery points cannot be deleted before they are a
# week old.
resource "aws_backup_vault_lock_configuration" "this" {
  count = local.create_backup && var.require_deletion_protection ? 1 : 0

  backup_vault_name  = aws_backup_vault.this[0].name
  min_retention_days = 7
}

# Receives a copy of every recovery point in the disaster-recovery region.
resource "aws_backup_vault" "secondary" {
  count = local.copy_backups ? 1 : 0

  region        = var.secondary_region
  name          = "${var.name_prefix}-dr"
  kms_key_arn   = local.secondary_kms_key_arn
  force_destroy = !var.require_deletion_protection

  tags = var.tags
}

resource "aws_backup_plan" "this" {
  count = local.create_backup ? 1 : 0

  name = var.name_prefix

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = local.backup_retention_days
    }

    dynamic "copy_action" {
      for_each = aws_backup_vault.secondary[*].arn

      content {
        destination_vault_arn = copy_action.value

        lifecycle {
          delete_after = local.backup_retention_days
        }
      }
    }
  }

  tags = var.tags
}

resource "aws_iam_role" "backup" {
  count = local.create_backup ? 1 : 0

  name = "${var.name_prefix}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.${local.dns_suffix}" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = local.create_backup ? toset(local.backup_role_policies) : []

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# Everything tagged for this plan is backed up: the database and, with
# enable_backup, the buckets.
resource "aws_backup_selection" "this" {
  count = local.create_backup ? 1 : 0

  name         = var.name_prefix
  plan_id      = aws_backup_plan.this[0].id
  iam_role_arn = aws_iam_role.backup[0].arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = local.backup_tag_key
    value = var.name_prefix
  }

  depends_on = [aws_iam_role_policy_attachment.backup]
}
