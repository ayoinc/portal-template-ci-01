locals {
  # Edge resources (CloudFront logs, CloudFront-scoped WAF logs and alarms)
  # live in the global region and need their own key there.
  create_global_kms_key = var.enable_kms && local.create_cdn && (var.enable_monitoring || var.enable_alerting)

  kms_deletion_window_days = var.require_deletion_protection ? 30 : 7

  # Lets IAM policies of this account grant use of the key. The services that
  # encrypt on behalf of a caller (S3, RDS, DynamoDB, Secrets Manager, ECR,
  # EKS, Backup) are authorised this way.
  kms_account_statement = {
    Sid       = "AccountAdministration"
    Effect    = "Allow"
    Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
    Action    = "kms:*"
    Resource  = "*"
  }

  # CloudWatch alarms publish to the encrypted alert topic. The topic policy
  # limits publishing to alarms of this account.
  kms_alarm_statement = {
    Sid       = "CloudWatchAlarmsToSns"
    Effect    = "Allow"
    Principal = { Service = "cloudwatch.${local.dns_suffix}" }
    Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
    Resource  = "*"
  }

  # CloudFront reads the encrypted objects of the storage bucket.
  kms_cdn_statement = {
    Sid       = "CloudFrontReadsStorage"
    Effect    = "Allow"
    Principal = { Service = "cloudfront.${local.dns_suffix}" }
    Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
    Resource  = "*"
    Condition = {
      StringLike = { "aws:SourceArn" = "arn:${local.partition}:cloudfront::${local.account_id}:distribution/*" }
    }
  }

  # CloudWatch Logs encrypts log groups of this account in the key's region.
  kms_logs_statements = {
    for region in distinct([var.region, local.global_region]) : region => {
      Sid       = "CloudWatchLogs"
      Effect    = "Allow"
      Principal = { Service = "logs.${region}.${local.dns_suffix}" }
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]
      Resource = "*"
      Condition = {
        ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${region}:${local.account_id}:*" }
      }
    }
  }

  # Tier security groups need a VPC; without one there is nothing to protect.
  create_tier_security_groups = var.enable_security_group_rules && local.network_available

  database_ports = {
    postgresql = 5432
    mysql      = 3306
    mongodb    = 27017
    redis      = 6379
  }
  database_port = lookup(local.database_ports, local.database_type, null)
}

# -----------------------------------------------------------------------------
# Customer-managed keys
# -----------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  count = var.enable_kms ? 1 : 0

  description             = "Encrypts the storage, databases, secrets and logs of ${var.name_prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = local.kms_deletion_window_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [local.kms_account_statement, local.kms_logs_statements[var.region]],
      var.enable_alerting ? [local.kms_alarm_statement] : [],
      local.create_cdn ? [local.kms_cdn_statement] : [],
    )
  })

  tags = var.tags
}

resource "aws_kms_alias" "this" {
  count = var.enable_kms ? 1 : 0

  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.this[0].key_id
}

# Encrypts the replicas and backup copies kept in the disaster-recovery region.
resource "aws_kms_key" "secondary" {
  count = var.enable_kms && var.enable_disaster_recovery ? 1 : 0

  region                  = var.secondary_region
  description             = "Encrypts the disaster-recovery copies of ${var.name_prefix} in ${var.secondary_region}"
  enable_key_rotation     = true
  deletion_window_in_days = local.kms_deletion_window_days

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.kms_account_statement]
  })

  tags = var.tags
}

resource "aws_kms_alias" "secondary" {
  count = var.enable_kms && var.enable_disaster_recovery ? 1 : 0

  region        = var.secondary_region
  name          = "alias/${var.name_prefix}-dr"
  target_key_id = aws_kms_key.secondary[0].key_id
}

# Encrypts the CDN and WAF logs and the alert topic kept in the global region.
resource "aws_kms_key" "global" {
  count = local.create_global_kms_key ? 1 : 0

  region                  = local.global_region
  description             = "Encrypts the CDN logs and alerts of ${var.name_prefix}"
  enable_key_rotation     = true
  deletion_window_in_days = local.kms_deletion_window_days

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [local.kms_account_statement, local.kms_logs_statements[local.global_region]],
      var.enable_alerting ? [local.kms_alarm_statement] : [],
    )
  })

  tags = var.tags
}

resource "aws_kms_alias" "global" {
  count = local.create_global_kms_key ? 1 : 0

  region        = local.global_region
  name          = "alias/${var.name_prefix}-edge"
  target_key_id = aws_kms_key.global[0].key_id
}

# -----------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------

# Holds the application's own configuration secrets; values are written by the
# application's deployment, never by Terraform.
resource "aws_secretsmanager_secret" "application" {
  count = var.enable_secrets_manager ? 1 : 0

  name        = "${var.name_prefix}/application"
  description = "Application secrets of ${var.name_prefix}"
  kms_key_id  = local.kms_key_arn

  # Without deletion protection the name is released at once, so the stack
  # can be destroyed and created again.
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

# -----------------------------------------------------------------------------
# Tiered security groups: web -> app -> data
# -----------------------------------------------------------------------------

resource "aws_security_group" "web" {
  count = local.create_tier_security_groups ? 1 : 0

  name        = "${var.name_prefix}-web"
  description = "Web tier of ${var.name_prefix}: load balancers facing the clients"
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-web"
    Tier = "web"
  })
}

resource "aws_vpc_security_group_ingress_rule" "web_https" {
  for_each = local.create_tier_security_groups ? toset(var.allowed_ingress_cidrs) : []

  security_group_id = aws_security_group.web[0].id
  description       = "HTTPS from an allowed client range"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "web_to_app" {
  count = local.create_tier_security_groups ? 1 : 0

  security_group_id            = aws_security_group.web[0].id
  description                  = "Forward requests to the app tier"
  referenced_security_group_id = aws_security_group.app[0].id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port

  tags = var.tags
}

resource "aws_security_group" "app" {
  count = local.create_tier_security_groups ? 1 : 0

  name        = "${var.name_prefix}-app"
  description = "App tier of ${var.name_prefix}: workloads behind the web tier"
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-app"
    Tier = "app"
  })
}

resource "aws_vpc_security_group_ingress_rule" "app_from_web" {
  count = local.create_tier_security_groups ? 1 : 0

  security_group_id            = aws_security_group.app[0].id
  description                  = "Requests from the web tier"
  referenced_security_group_id = aws_security_group.web[0].id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "app_to_data" {
  count = local.create_tier_security_groups && local.database_in_vpc ? 1 : 0

  security_group_id            = aws_security_group.app[0].id
  description                  = "Queries to the data tier"
  referenced_security_group_id = aws_security_group.data[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.database_port
  to_port                      = local.database_port

  tags = var.tags
}

# Workloads call AWS APIs and external services over HTTPS through the NAT gateways.
# trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "app_https" {
  count = local.create_tier_security_groups ? 1 : 0

  security_group_id = aws_security_group.app[0].id
  description       = "HTTPS to AWS APIs and external services"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = var.tags
}

resource "aws_security_group" "data" {
  count = local.database_in_vpc ? 1 : 0

  name        = "${var.name_prefix}-data"
  description = "Data tier of ${var.name_prefix}: the ${var.database_type} database"
  vpc_id      = local.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-data"
    Tier = "data"
  })

  lifecycle {
    precondition {
      condition     = local.network_available
      error_message = local.network_required
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  count = local.database_in_vpc && local.create_tier_security_groups ? 1 : 0

  security_group_id            = aws_security_group.data[0].id
  description                  = "Database connections from the app tier"
  referenced_security_group_id = aws_security_group.app[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.database_port
  to_port                      = local.database_port

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "data_from_cluster" {
  count = local.database_in_vpc && local.create_tier_security_groups && var.enable_kubernetes ? 1 : 0

  security_group_id            = aws_security_group.data[0].id
  description                  = "Database connections from the Kubernetes cluster"
  referenced_security_group_id = aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.database_port
  to_port                      = local.database_port

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "data_from_network" {
  count = local.database_in_vpc && !var.enable_security_group_rules ? 1 : 0

  security_group_id = aws_security_group.data[0].id
  description       = "Database connections from inside the VPC"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = local.database_port
  to_port           = local.database_port

  tags = var.tags
}
