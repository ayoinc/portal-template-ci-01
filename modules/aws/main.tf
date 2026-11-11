data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Suffix that keeps globally unique names (S3 buckets, final snapshots) unique.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix

  # CloudFront reports its metrics in us-east-1 and reads its WAF web ACLs,
  # log groups and alarm topics from there.
  global_region = "us-east-1"

  is_production = var.environment == "production"

  # Cheaper, less redundant choices apply outside production only.
  cost_optimized = var.enable_cost_optimization && !local.is_production

  # ---------------------------------------------------------------------------
  # Components derived from the inputs
  # ---------------------------------------------------------------------------

  database_type      = var.enable_database ? var.database_type : "none"
  create_rds         = contains(["postgresql", "mysql"], local.database_type)
  create_docdb       = local.database_type == "mongodb"
  create_redis       = local.database_type == "redis"
  create_dynamodb    = local.database_type == "dynamodb"
  database_in_vpc    = local.create_rds || local.create_docdb || local.create_redis
  create_registry    = contains(["container-platform", "ml-platform", "serverless-platform"], var.infrastructure_type)
  create_data_lake   = contains(["data-platform", "ml-platform"], var.infrastructure_type)
  create_private_dns = var.infrastructure_type == "networking-foundation"

  # The WAF protects the CDN when there is one, otherwise it is regional.
  create_cdn          = var.enable_cdn
  create_global_waf   = var.enable_waf && local.create_cdn
  create_regional_waf = var.enable_waf && !local.create_cdn

  # ---------------------------------------------------------------------------
  # Network in use: the created VPC or the one passed in
  # ---------------------------------------------------------------------------

  network_available = var.enable_networking || var.existing_network != null
  network_required  = "This component needs a network: set enable_networking to true or pass existing_network (network_id, public_subnet_ids, private_subnet_ids)."

  vpc_id             = var.enable_networking ? one(aws_vpc.this[*].id) : try(var.existing_network.network_id, null)
  vpc_cidr           = var.enable_networking ? var.network_cidr : one(data.aws_vpc.existing[*].cidr_block)
  public_subnet_ids  = var.enable_networking ? aws_subnet.public[*].id : try(var.existing_network.public_subnet_ids, [])
  private_subnet_ids = var.enable_networking ? aws_subnet.private[*].id : try(var.existing_network.private_subnet_ids, [])

  # ---------------------------------------------------------------------------
  # Encryption keys: null selects the AWS-managed key of each service
  # ---------------------------------------------------------------------------

  kms_key_arn           = one(aws_kms_key.this[*].arn)
  secondary_kms_key_arn = one(aws_kms_key.secondary[*].arn)
  global_kms_key_arn    = one(aws_kms_key.global[*].arn)

  # ---------------------------------------------------------------------------
  # Logs
  # ---------------------------------------------------------------------------

  # CloudWatch Logs accepts these retention periods only.
  cloudwatch_retention_periods = [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653]
  log_retention_days           = [for days in local.cloudwatch_retention_periods : days if days >= var.log_retention_days][0]

  # ---------------------------------------------------------------------------
  # Backup
  # ---------------------------------------------------------------------------

  # Databases AWS Backup can protect. ElastiCache keeps its own snapshots.
  database_backed_up = local.create_rds || local.create_docdb || local.create_dynamodb

  # Cross-region database protection is a backup copy, so disaster recovery
  # brings the backup plan with it even when enable_backup is false.
  create_backup = var.enable_backup || (var.enable_disaster_recovery && local.database_backed_up)

  # Resources carrying this tag are picked up by the backup plan.
  backup_tag_key      = "BackupPlan"
  database_backup_tag = local.create_backup ? { (local.backup_tag_key) = var.name_prefix } : {}
  storage_backup_tag  = var.enable_backup ? { (local.backup_tag_key) = var.name_prefix } : {}

  backup_retention_days = var.enable_backup ? 35 : 7
}
