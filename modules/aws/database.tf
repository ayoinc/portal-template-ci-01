locals {
  # Engine and default (current major) version per database type.
  database_engines = {
    postgresql = { engine = "postgres", version = "17" }
    mysql      = { engine = "mysql", version = "8.4" }
    mongodb    = { engine = "docdb", version = "5.0.0" }
    redis      = { engine = "redis", version = "7.1" }
  }
  database_engine         = try(local.database_engines[local.database_type].engine, null)
  database_engine_version = try(coalesce(var.database_engine_version, local.database_engines[local.database_type].version), null)

  # Parameter group families: postgres17, mysql8.4, docdb5.0.
  database_version_parts = split(".", coalesce(local.database_engine_version, "0.0"))
  database_parameter_family = (
    local.database_type == "postgresql"
    ? "postgres${local.database_version_parts[0]}"
    : "${coalesce(local.database_engine, "none")}${join(".", slice(concat(local.database_version_parts, ["0"]), 0, 2))}"
  )

  database_name     = "app"
  database_username = "dbadmin"

  rds_instance_class   = local.cost_optimized ? "db.t4g.micro" : local.is_production ? "db.m6g.large" : "db.t4g.medium"
  docdb_instance_class = local.is_production ? "db.r6g.large" : "db.t4g.medium"
  redis_node_type      = local.cost_optimized ? "cache.t4g.micro" : local.is_production ? "cache.m6g.large" : "cache.t4g.small"

  # Performance Insights is not offered for MySQL on micro instances.
  rds_performance_insights = !(local.database_type == "mysql" && local.cost_optimized)

  # Log types each engine can export to CloudWatch Logs.
  rds_log_types   = local.database_type == "postgresql" ? ["postgresql", "upgrade"] : ["error", "slowquery"]
  docdb_log_types = ["audit", "profiler"]
  redis_log_types = ["slow-log", "engine-log"]

  # RDS and DocumentDB keep the master password in Secrets Manager themselves.
  # Otherwise, and for the Redis auth token, a password is generated here.
  database_password_managed   = (local.create_rds || local.create_docdb) && var.enable_secrets_manager
  database_password_generated = local.create_redis || ((local.create_rds || local.create_docdb) && !var.enable_secrets_manager)

  database_final_snapshot = var.require_deletion_protection ? "${var.name_prefix}-final-${random_id.suffix.hex}" : null
}

resource "random_password" "database" {
  count = local.database_password_generated ? 1 : 0

  # Letters and digits only: valid as an RDS or DocumentDB password and as an
  # ElastiCache auth token alike.
  length  = 40
  special = false
}

# -----------------------------------------------------------------------------
# RDS for PostgreSQL / MySQL
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  count = local.create_rds ? 1 : 0

  name        = var.name_prefix
  description = "Private subnets of the ${var.name_prefix} database"
  subnet_ids  = local.private_subnet_ids

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}

# Rejects connections that are not encrypted in transit.
resource "aws_db_parameter_group" "this" {
  count = local.create_rds ? 1 : 0

  name        = "${var.name_prefix}-${replace(local.database_parameter_family, ".", "-")}"
  description = "TLS-only connections to the ${var.name_prefix} database"
  family      = local.database_parameter_family

  parameter {
    name  = local.database_type == "postgresql" ? "rds.force_ssl" : "require_secure_transport"
    value = "1"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# RDS writes exported logs to these names; creating them first sets the
# retention and the encryption key.
resource "aws_cloudwatch_log_group" "rds" {
  for_each = local.create_rds && var.enable_monitoring ? toset(local.rds_log_types) : []

  name              = "/aws/rds/instance/${var.name_prefix}/${each.value}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

resource "aws_db_instance" "this" {
  count = local.create_rds ? 1 : 0

  identifier = var.name_prefix

  engine         = local.database_engine
  engine_version = local.database_engine_version
  instance_class = local.rds_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = local.kms_key_arn

  db_name  = local.database_name
  username = local.database_username

  manage_master_user_password   = local.database_password_managed ? true : null
  master_user_secret_kms_key_id = local.database_password_managed ? local.kms_key_arn : null
  password                      = local.database_password_managed ? null : random_password.database[0].result

  db_subnet_group_name   = aws_db_subnet_group.this[0].name
  vpc_security_group_ids = [aws_security_group.data[0].id]
  parameter_group_name   = aws_db_parameter_group.this[0].name
  publicly_accessible    = false
  multi_az               = local.is_production

  iam_database_authentication_enabled = true

  performance_insights_enabled          = local.rds_performance_insights
  performance_insights_kms_key_id       = local.rds_performance_insights ? local.kms_key_arn : null
  performance_insights_retention_period = local.rds_performance_insights ? 7 : null

  enabled_cloudwatch_logs_exports = var.enable_monitoring ? local.rds_log_types : []

  backup_retention_period    = local.backup_retention_days
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = !local.is_production

  deletion_protection       = var.require_deletion_protection
  delete_automated_backups  = !var.require_deletion_protection
  skip_final_snapshot       = !var.require_deletion_protection
  final_snapshot_identifier = local.database_final_snapshot

  tags = merge(var.tags, local.database_backup_tag)

  depends_on = [aws_cloudwatch_log_group.rds]
}

# -----------------------------------------------------------------------------
# DocumentDB (MongoDB compatible)
# -----------------------------------------------------------------------------

resource "aws_docdb_subnet_group" "this" {
  count = local.create_docdb ? 1 : 0

  name        = var.name_prefix
  description = "Private subnets of the ${var.name_prefix} database"
  subnet_ids  = local.private_subnet_ids

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}

resource "aws_docdb_cluster_parameter_group" "this" {
  count = local.create_docdb ? 1 : 0

  name        = "${var.name_prefix}-${replace(local.database_parameter_family, ".", "-")}"
  description = "TLS-only connections and audit logging for the ${var.name_prefix} database"
  family      = local.database_parameter_family

  parameter {
    name  = "tls"
    value = "enabled"
  }

  parameter {
    name  = "audit_logs"
    value = var.enable_monitoring ? "enabled" : "disabled"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "docdb" {
  for_each = local.create_docdb && var.enable_monitoring ? toset(local.docdb_log_types) : []

  name              = "/aws/docdb/${var.name_prefix}/${each.value}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

resource "aws_docdb_cluster" "this" {
  count = local.create_docdb ? 1 : 0

  cluster_identifier = var.name_prefix

  engine         = local.database_engine
  engine_version = local.database_engine_version

  master_username             = local.database_username
  manage_master_user_password = local.database_password_managed ? true : null
  master_password             = local.database_password_managed ? null : random_password.database[0].result

  storage_encrypted = true
  kms_key_id        = local.kms_key_arn

  db_subnet_group_name            = aws_docdb_subnet_group.this[0].name
  vpc_security_group_ids          = [aws_security_group.data[0].id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.this[0].name

  enabled_cloudwatch_logs_exports = var.enable_monitoring ? local.docdb_log_types : []

  backup_retention_period = local.backup_retention_days
  apply_immediately       = !local.is_production

  deletion_protection       = var.require_deletion_protection
  skip_final_snapshot       = !var.require_deletion_protection
  final_snapshot_identifier = local.database_final_snapshot

  tags = merge(var.tags, local.database_backup_tag)

  depends_on = [aws_cloudwatch_log_group.docdb]
}

# Production runs a second instance in another zone for failover.
resource "aws_docdb_cluster_instance" "this" {
  count = local.create_docdb ? (local.is_production ? 2 : 1) : 0

  identifier         = "${var.name_prefix}-${count.index + 1}"
  cluster_identifier = aws_docdb_cluster.this[0].id
  instance_class     = local.docdb_instance_class

  auto_minor_version_upgrade = true
  apply_immediately          = !local.is_production

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ElastiCache for Redis
# -----------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  count = local.create_redis ? 1 : 0

  name        = var.name_prefix
  description = "Private subnets of the ${var.name_prefix} cache"
  subnet_ids  = local.private_subnet_ids

  tags = var.tags

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}

resource "aws_cloudwatch_log_group" "redis" {
  for_each = local.create_redis && var.enable_monitoring ? toset(local.redis_log_types) : []

  name              = "/aws/vendedlogs/elasticache/${var.name_prefix}/${each.value}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

resource "aws_elasticache_replication_group" "this" {
  count = local.create_redis ? 1 : 0

  replication_group_id = var.name_prefix
  description          = "Redis of ${var.name_prefix}"

  engine         = local.database_engine
  engine_version = local.database_engine_version
  node_type      = local.redis_node_type
  port           = local.database_port

  # Production runs a replica in another zone and fails over to it.
  num_cache_clusters         = local.is_production ? 2 : 1
  automatic_failover_enabled = local.is_production
  multi_az_enabled           = local.is_production

  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [aws_security_group.data[0].id]

  at_rest_encryption_enabled = true
  kms_key_id                 = local.kms_key_arn
  transit_encryption_enabled = true
  auth_token                 = random_password.database[0].result
  auth_token_update_strategy = "ROTATE"

  snapshot_retention_limit   = local.backup_retention_days
  final_snapshot_identifier  = local.database_final_snapshot
  auto_minor_version_upgrade = true
  apply_immediately          = !local.is_production

  dynamic "log_delivery_configuration" {
    for_each = aws_cloudwatch_log_group.redis

    content {
      destination      = log_delivery_configuration.value.name
      destination_type = "cloudwatch-logs"
      log_format       = "json"
      log_type         = log_delivery_configuration.key
    }
  }

  tags = var.tags
}

# Connection details and auth token of the cache, for workloads that read
# their configuration from Secrets Manager.
resource "aws_secretsmanager_secret" "database" {
  count = local.create_redis && var.enable_secrets_manager ? 1 : 0

  name                    = "${var.name_prefix}/database"
  description             = "Redis endpoint and auth token of ${var.name_prefix}"
  kms_key_id              = local.kms_key_arn
  recovery_window_in_days = var.require_deletion_protection ? 30 : 0

  dynamic "replica" {
    for_each = var.enable_disaster_recovery ? [var.secondary_region] : []

    content {
      region     = replica.value
      kms_key_id = local.secondary_kms_key_arn
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "database" {
  count = local.create_redis && var.enable_secrets_manager ? 1 : 0

  secret_id = aws_secretsmanager_secret.database[0].id

  secret_string = jsonencode({
    engine     = local.database_engine
    host       = aws_elasticache_replication_group.this[0].primary_endpoint_address
    port       = local.database_port
    auth_token = random_password.database[0].result
    tls        = true
  })
}

# -----------------------------------------------------------------------------
# DynamoDB
# -----------------------------------------------------------------------------

# A single-table layout: a generic partition key and sort key.
resource "aws_dynamodb_table" "this" {
  count = local.create_dynamodb ? 1 : 0

  name         = var.name_prefix
  billing_mode = "PAY_PER_REQUEST"
  table_class  = "STANDARD"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = local.backup_retention_days
  }

  # Without a customer-managed key DynamoDB encrypts with a key it owns.
  server_side_encryption {
    enabled     = var.enable_kms
    kms_key_arn = local.kms_key_arn
  }

  deletion_protection_enabled = var.require_deletion_protection

  tags = merge(var.tags, local.database_backup_tag)
}
