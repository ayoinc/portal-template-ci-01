# Plan-only tests against a mocked AWS provider: no credentials, no resources.
# Run with: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.50.0.0/16"
    }
  }
}

# The smallest stack: a network and nothing else.
variables {
  name_prefix                 = "acme-dev"
  environment                 = "development"
  region                      = "eu-west-2"
  tags                        = { Project = "acme" }
  infrastructure_type         = "web-application"
  enable_networking           = true
  network_cidr                = "10.0.0.0/16"
  enable_security_group_rules = false
  enable_kubernetes           = false
  node_size                   = "medium"
  enable_autoscaling          = false
  min_nodes                   = 2
  max_nodes                   = 5
  enable_database             = false
  database_type               = "postgresql"
  enable_storage              = false
  enable_cdn                  = false
  enable_waf                  = false
  enable_secrets_manager      = false
  enable_kms                  = false
  enable_backup               = false
  enable_monitoring           = false
  enable_managed_prometheus   = false
  enable_alerting             = false
  log_retention_days          = 30
  enable_disaster_recovery    = false
  enable_cost_optimization    = false
  require_deletion_protection = false
  require_flow_logs           = false
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

run "defaults_minimal" {
  command = plan

  assert {
    condition     = aws_vpc.this[0].cidr_block == "10.0.0.0/16"
    error_message = "The VPC must use network_cidr."
  }

  assert {
    condition     = aws_subnet.public[*].cidr_block == ["10.0.0.0/20", "10.0.16.0/20"]
    error_message = "Public subnets must be sixteenths of the first quarter of the VPC."
  }

  assert {
    condition     = aws_subnet.private[*].cidr_block == ["10.0.64.0/18", "10.0.128.0/18"]
    error_message = "Private subnets must be the following quarters of the VPC."
  }

  assert {
    condition     = aws_subnet.private[*].availability_zone == ["eu-west-2a", "eu-west-2b"]
    error_message = "Subnets must be spread over two availability zones."
  }

  assert {
    condition     = alltrue([for subnet in aws_subnet.public : !subnet.map_public_ip_on_launch])
    error_message = "Public subnets must not hand out public addresses by default."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "Each zone gets a NAT gateway unless cost optimisation is on."
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2 && length(output.private_subnet_ids) == 2
    error_message = "The subnets must be exposed as outputs."
  }

  assert {
    condition = (
      length(aws_eks_cluster.this) == 0 &&
      length(aws_db_instance.this) == 0 &&
      length(aws_docdb_cluster.this) == 0 &&
      length(aws_elasticache_replication_group.this) == 0 &&
      length(aws_dynamodb_table.this) == 0 &&
      length(aws_s3_bucket.this) == 0 &&
      length(aws_cloudfront_distribution.this) == 0 &&
      length(aws_wafv2_web_acl.this) == 0 &&
      length(aws_kms_key.this) == 0 &&
      length(aws_secretsmanager_secret.application) == 0 &&
      length(aws_backup_vault.this) == 0 &&
      length(aws_cloudwatch_log_group.central) == 0 &&
      length(aws_flow_log.this) == 0 &&
      length(aws_sns_topic.alerts) == 0 &&
      length(aws_prometheus_workspace.this) == 0 &&
      length(aws_ecr_repository.this) == 0 &&
      length(aws_route53_zone.private) == 0 &&
      length(aws_security_group.web) == 0
    )
    error_message = "Nothing but the network may be created when every feature is off."
  }

  assert {
    condition = (
      output.kubernetes_cluster_name == null &&
      output.kubernetes_cluster_endpoint == null &&
      output.database_endpoint == null &&
      output.database_name == null &&
      output.database_credentials_secret_id == null &&
      output.storage_bucket_name == null &&
      output.data_lake_bucket_names == [] &&
      output.cdn_domain_name == null &&
      output.waf_id == null &&
      output.kms_key_id == null &&
      output.secrets_store_id == null &&
      output.container_registry_url == null &&
      output.private_dns_zone_name == null &&
      output.backup_vault_id == null &&
      output.log_destination_id == null &&
      output.alert_target_id == null &&
      output.prometheus_endpoint == null &&
      output.grafana_endpoint == null
    )
    error_message = "Outputs of components that are not created must be null or empty."
  }
}

run "cost_optimization_outside_production" {
  command = plan

  variables {
    enable_cost_optimization = true
    enable_kubernetes        = true
    enable_database          = true
    enable_storage           = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_route.private_nat) == 2
    error_message = "Cost optimisation outside production shares a single NAT gateway."
  }

  assert {
    condition     = aws_eks_node_group.this[0].capacity_type == "SPOT" && length(aws_eks_node_group.this[0].instance_types) == 3
    error_message = "Cost optimisation outside production runs Spot nodes over several instance types."
  }

  assert {
    condition     = aws_db_instance.this[0].instance_class == "db.t4g.micro"
    error_message = "Cost optimisation outside production uses the smallest database class."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this["storage"].rule[0].status == "Enabled"
    error_message = "Cost optimisation tiers the storage bucket."
  }
}

run "existing_network" {
  command = plan

  variables {
    enable_networking = false
    existing_network = {
      network_id         = "vpc-0123456789abcdef0"
      public_subnet_ids  = ["subnet-0aaa", "subnet-0bbb"]
      private_subnet_ids = ["subnet-0ccc", "subnet-0ddd"]
    }
    enable_kubernetes = true
    enable_database   = true
    require_flow_logs = true
  }

  assert {
    condition     = length(aws_vpc.this) == 0 && length(aws_subnet.private) == 0 && length(aws_nat_gateway.this) == 0
    error_message = "No network may be created when an existing one is used."
  }

  assert {
    condition     = output.network_id == "vpc-0123456789abcdef0" && output.private_subnet_ids == tolist(["subnet-0ccc", "subnet-0ddd"])
    error_message = "The existing network must be passed through to the outputs."
  }

  assert {
    condition     = aws_db_subnet_group.this[0].subnet_ids == toset(["subnet-0ccc", "subnet-0ddd"])
    error_message = "The database must use the existing private subnets."
  }

  assert {
    condition     = aws_eks_cluster.this[0].vpc_config[0].subnet_ids == toset(["subnet-0ccc", "subnet-0ddd"])
    error_message = "The cluster must use the existing private subnets."
  }

  assert {
    condition     = aws_security_group.data[0].vpc_id == "vpc-0123456789abcdef0"
    error_message = "Security groups must be created in the existing VPC."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.data_from_network[0].cidr_ipv4 == "10.50.0.0/16"
    error_message = "Without tier rules the database accepts the CIDR of the existing VPC."
  }

  assert {
    condition     = aws_flow_log.this[0].vpc_id == "vpc-0123456789abcdef0" && length(aws_cloudwatch_log_group.flow_logs) == 1
    error_message = "Flow logs of the existing VPC go to their own log group when monitoring is off."
  }
}

run "missing_network_fails" {
  command = plan

  variables {
    enable_networking = false
    enable_database   = true
  }

  expect_failures = [
    aws_security_group.data,
    aws_db_subnet_group.this,
  ]
}

run "missing_network_is_fine_without_network_components" {
  command = plan

  variables {
    enable_networking           = false
    enable_security_group_rules = true
    require_flow_logs           = true
    enable_storage              = true
    enable_database             = true
    database_type               = "dynamodb"
  }

  assert {
    condition     = output.network_id == null && length(output.private_subnet_ids) == 0 && length(aws_security_group.web) == 0 && length(aws_flow_log.this) == 0
    error_message = "Components that need no network must plan without one."
  }

  assert {
    condition     = length(aws_dynamodb_table.this) == 1 && length(aws_s3_bucket.this) == 1
    error_message = "DynamoDB and S3 do not need a network."
  }
}

run "tiered_security_groups" {
  command = plan

  variables {
    enable_security_group_rules = true
    allowed_ingress_cidrs       = ["203.0.113.0/24", "198.51.100.0/24"]
    enable_database             = true
    enable_kubernetes           = true
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.web_https) == 2 && aws_vpc_security_group_ingress_rule.web_https["203.0.113.0/24"].from_port == 443
    error_message = "The web tier accepts HTTPS from each allowed client range."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_from_web[0].from_port == 8080
    error_message = "The app tier accepts the app port from the web tier."
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.data_from_app) == 1 &&
      length(aws_vpc_security_group_ingress_rule.data_from_cluster) == 1 &&
      length(aws_vpc_security_group_ingress_rule.data_from_network) == 0 &&
      aws_vpc_security_group_ingress_rule.data_from_app[0].from_port == 5432
    )
    error_message = "With tier rules the database accepts the app tier and the cluster only."
  }
}

# -----------------------------------------------------------------------------
# Everything on, production
# -----------------------------------------------------------------------------

run "everything_on_production" {
  command = plan

  variables {
    name_prefix                 = "acme-prod"
    environment                 = "production"
    secondary_region            = "eu-west-1"
    infrastructure_type         = "ml-platform"
    allowed_ingress_cidrs       = ["203.0.113.0/24"]
    enable_security_group_rules = true
    enable_kubernetes           = true
    enable_autoscaling          = true
    enable_database             = true
    enable_storage              = true
    enable_cdn                  = true
    enable_waf                  = true
    enable_secrets_manager      = true
    enable_kms                  = true
    enable_backup               = true
    enable_monitoring           = true
    enable_managed_prometheus   = true
    enable_alerting             = true
    alert_email                 = "platform@example.com"
    log_retention_days          = 100
    enable_disaster_recovery    = true
    enable_cost_optimization    = true
    require_deletion_protection = true
    require_flow_logs           = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 2
    error_message = "Production keeps a NAT gateway per zone even with cost optimisation."
  }

  assert {
    condition = (
      !aws_eks_cluster.this[0].vpc_config[0].endpoint_public_access &&
      aws_eks_cluster.this[0].vpc_config[0].endpoint_private_access &&
      length(aws_eks_cluster.this[0].encryption_config) == 1 &&
      length(aws_eks_cluster.this[0].enabled_cluster_log_types) == 5 &&
      aws_eks_cluster.this[0].deletion_protection
    )
    error_message = "The cluster must be private, encrypt secrets, log the control plane and be protected."
  }

  assert {
    condition = (
      aws_eks_node_group.this[0].capacity_type == "ON_DEMAND" &&
      aws_eks_node_group.this[0].instance_types == tolist(["c6i.xlarge"]) &&
      aws_eks_node_group.this[0].scaling_config[0].min_size == 2 &&
      aws_eks_node_group.this[0].scaling_config[0].max_size == 5
    )
    error_message = "Production nodes are on-demand, sized by node_size and scale between min_nodes and max_nodes."
  }

  assert {
    condition     = aws_launch_template.nodes[0].metadata_options[0].http_tokens == "required"
    error_message = "Nodes must require IMDSv2."
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.cluster_autoscaler) == 1 && length(aws_eks_addon.container_insights) == 1
    error_message = "Autoscaling and monitoring must wire their roles into the cluster."
  }

  assert {
    condition = (
      aws_db_instance.this[0].engine == "postgres" &&
      aws_db_instance.this[0].instance_class == "db.m6g.large" &&
      aws_db_instance.this[0].multi_az &&
      aws_db_instance.this[0].storage_encrypted &&
      !aws_db_instance.this[0].publicly_accessible &&
      aws_db_instance.this[0].deletion_protection &&
      aws_db_instance.this[0].backup_retention_period == 35 &&
      aws_db_instance.this[0].manage_master_user_password
    )
    error_message = "The production database must be multi-AZ, encrypted, private, protected and keep 35 days of backups."
  }

  assert {
    condition     = length(random_password.database) == 0 && nonsensitive(output.database_password == null)
    error_message = "No password may be generated when RDS keeps it in Secrets Manager."
  }

  assert {
    condition     = length(aws_s3_bucket.this) == 3 && length(aws_s3_bucket.replica) == 3
    error_message = "The storage bucket and both data-lake buckets must exist and be replicated."
  }

  assert {
    condition     = alltrue([for bucket in aws_s3_bucket.replica : bucket.region == "eu-west-1"])
    error_message = "Replica buckets must live in the secondary region."
  }

  assert {
    condition = alltrue([
      for role in ["storage", "raw", "curated"] :
      aws_s3_bucket_versioning.this[role].versioning_configuration[0].status == "Enabled" &&
      one(aws_s3_bucket_server_side_encryption_configuration.this[role].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" &&
      aws_s3_bucket_public_access_block.this[role].block_public_policy &&
      aws_s3_bucket_public_access_block.this[role].restrict_public_buckets
    ])
    error_message = "Every bucket must be versioned, encrypted with the customer-managed key and private."
  }

  assert {
    condition     = output.storage_bucket_name != null && length(output.data_lake_bucket_names) == 2
    error_message = "Bucket names must be exposed as outputs."
  }

  assert {
    condition     = aws_cloudfront_distribution.this[0].default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https"
    error_message = "The CDN must serve HTTPS only."
  }

  assert {
    condition     = aws_wafv2_web_acl.this[0].scope == "CLOUDFRONT" && aws_wafv2_web_acl.this[0].region == "us-east-1"
    error_message = "With a CDN the web ACL is CloudFront-scoped in us-east-1."
  }

  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation && aws_kms_key.this[0].deletion_window_in_days == 30
    error_message = "The key must rotate and keep the longest deletion window under deletion protection."
  }

  assert {
    condition     = aws_kms_key.secondary[0].region == "eu-west-1" && aws_kms_key.global[0].region == "us-east-1"
    error_message = "Disaster-recovery and CDN resources get keys in their own regions."
  }

  assert {
    condition     = aws_secretsmanager_secret.application[0].recovery_window_in_days == 30
    error_message = "Secrets keep the recovery window under deletion protection."
  }

  assert {
    condition = (
      length(aws_backup_vault_lock_configuration.this) == 1 &&
      aws_backup_vault.secondary[0].region == "eu-west-1" &&
      length(aws_backup_selection.this) == 1
    )
    error_message = "Backups must be locked, selected by tag and copied to the secondary region."
  }

  assert {
    condition     = aws_cloudwatch_log_group.central[0].retention_in_days == 120
    error_message = "Log retention must be rounded up to a period CloudWatch Logs supports."
  }

  assert {
    condition     = length(aws_flow_log.this) == 1 && length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "Flow logs go to the central log group when monitoring is on."
  }

  assert {
    condition     = length(aws_cloudwatch_dashboard.this) == 1
    error_message = "Monitoring must create a dashboard."
  }

  assert {
    condition = (
      aws_sns_topic_subscription.alert_email[0].endpoint == "platform@example.com" &&
      length(aws_sns_topic_subscription.global_alert_email) == 1
    )
    error_message = "alert_email must be subscribed to the alert topics."
  }

  assert {
    condition = alltrue([
      for name in ["database-cpu", "database-storage", "cluster-api-errors", "storage-errors", "storage-replication", "backup-failures"] :
      contains(keys(aws_cloudwatch_metric_alarm.this), name)
    ])
    error_message = "Alarms must cover the database, the cluster, storage and backups."
  }

  assert {
    condition     = sort(keys(aws_cloudwatch_metric_alarm.global)) == tolist(["cdn-errors", "waf-blocked-requests"])
    error_message = "CDN and WAF alarms must be created in the global region."
  }

  assert {
    condition = (
      length(aws_prometheus_workspace.this) == 1 &&
      length(aws_prometheus_scraper.this) == 1 &&
      aws_grafana_workspace.this[0].authentication_providers == tolist(["SAML"])
    )
    error_message = "Managed Prometheus must come with a scraper for the cluster and a Grafana workspace."
  }

  assert {
    condition = (
      aws_ecr_repository.this[0].image_tag_mutability == "IMMUTABLE" &&
      aws_ecr_repository.this[0].image_scanning_configuration[0].scan_on_push
    )
    error_message = "The registry must have immutable tags and scan on push."
  }
}

# -----------------------------------------------------------------------------
# Database types
# -----------------------------------------------------------------------------

run "database_postgresql" {
  command = plan

  variables {
    enable_database = true
    database_type   = "postgresql"
  }

  assert {
    condition = (
      aws_db_instance.this[0].engine == "postgres" &&
      aws_db_instance.this[0].engine_version == "17" &&
      aws_db_instance.this[0].instance_class == "db.t4g.medium" &&
      !aws_db_instance.this[0].multi_az &&
      aws_db_instance.this[0].backup_retention_period == 7 &&
      aws_db_instance.this[0].storage_encrypted
    )
    error_message = "PostgreSQL must run on RDS, single-AZ outside production, encrypted, with 7 days of backups."
  }

  assert {
    condition     = aws_db_parameter_group.this[0].family == "postgres17"
    error_message = "The parameter group family must follow the engine version."
  }

  assert {
    condition     = length(random_password.database) == 1 && output.database_credentials_secret_id == null
    error_message = "Without Secrets Manager the password is generated and returned as an output."
  }

  assert {
    condition     = output.database_name == "app" && output.database_port == 5432
    error_message = "Database name and port must be exposed as outputs."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.data_from_network[0].cidr_ipv4 == "10.0.0.0/16"
    error_message = "Without tier rules the database accepts the VPC CIDR only."
  }
}

run "database_mysql" {
  command = plan

  variables {
    enable_database        = true
    database_type          = "mysql"
    enable_secrets_manager = true
  }

  assert {
    condition = (
      aws_db_instance.this[0].engine == "mysql" &&
      aws_db_instance.this[0].engine_version == "8.4" &&
      aws_db_instance.this[0].manage_master_user_password &&
      aws_db_parameter_group.this[0].family == "mysql8.4"
    )
    error_message = "MySQL must run on RDS 8.4 with the password kept in Secrets Manager."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.data_from_network[0].from_port == 3306
    error_message = "The database security group must open the MySQL port."
  }
}

run "database_mongodb" {
  command = plan

  variables {
    enable_database = true
    database_type   = "mongodb"
  }

  assert {
    condition = (
      aws_docdb_cluster.this[0].engine == "docdb" &&
      aws_docdb_cluster.this[0].storage_encrypted &&
      aws_docdb_cluster.this[0].backup_retention_period == 7 &&
      length(aws_docdb_cluster_instance.this) == 1 &&
      aws_docdb_cluster_parameter_group.this[0].family == "docdb5.0"
    )
    error_message = "MongoDB must be an encrypted DocumentDB cluster with one instance outside production."
  }

  assert {
    condition     = length(aws_db_instance.this) == 0 && output.database_port == 27017 && output.database_name == null
    error_message = "DocumentDB must not create RDS resources."
  }
}

run "database_redis" {
  command = plan

  variables {
    enable_database        = true
    database_type          = "redis"
    enable_secrets_manager = true
  }

  assert {
    condition = (
      aws_elasticache_replication_group.this[0].engine == "redis" &&
      aws_elasticache_replication_group.this[0].transit_encryption_enabled &&
      aws_elasticache_replication_group.this[0].at_rest_encryption_enabled == "true" &&
      aws_elasticache_replication_group.this[0].num_cache_clusters == 1 &&
      aws_elasticache_replication_group.this[0].node_type == "cache.t4g.small"
    )
    error_message = "Redis must be an ElastiCache replication group encrypted at rest and in transit."
  }

  assert {
    condition     = length(random_password.database) == 1 && length(aws_secretsmanager_secret_version.database) == 1
    error_message = "The Redis auth token must be generated and stored in Secrets Manager."
  }

  assert {
    condition     = nonsensitive(output.database_password == null)
    error_message = "The auth token must not be an output when it is kept in Secrets Manager."
  }
}

run "database_dynamodb" {
  command = plan

  variables {
    enable_database = true
    database_type   = "dynamodb"
    enable_backup   = true
  }

  assert {
    condition = (
      aws_dynamodb_table.this[0].billing_mode == "PAY_PER_REQUEST" &&
      aws_dynamodb_table.this[0].point_in_time_recovery[0].enabled &&
      aws_dynamodb_table.this[0].point_in_time_recovery[0].recovery_period_in_days == 35
    )
    error_message = "DynamoDB must be on-demand with point-in-time recovery, 35 days with backup enabled."
  }

  assert {
    condition     = length(aws_security_group.data) == 0 && length(random_password.database) == 0
    error_message = "DynamoDB needs neither a security group nor a password."
  }

  assert {
    condition     = output.database_endpoint == "dynamodb.eu-west-2.amazonaws.com" && output.database_name == "acme-dev"
    error_message = "The DynamoDB endpoint and table name must be exposed as outputs."
  }

  assert {
    condition     = aws_dynamodb_table.this[0].tags["BackupPlan"] == "acme-dev" && length(aws_backup_plan.this) == 1
    error_message = "The table must be selected by the backup plan."
  }
}

run "rejects_unknown_database_type" {
  command = plan

  variables {
    database_type = "cosmosdb"
  }

  expect_failures = [var.database_type]
}

# -----------------------------------------------------------------------------
# Infrastructure types
# -----------------------------------------------------------------------------

run "type_data_platform" {
  command = plan

  variables {
    infrastructure_type = "data-platform"
  }

  assert {
    condition     = sort(keys(aws_s3_bucket.this)) == tolist(["curated", "raw"]) && sort(keys(aws_s3_bucket_lifecycle_configuration.this)) == tolist(["curated", "raw"])
    error_message = "A data platform gets raw and curated buckets with lifecycle rules."
  }

  assert {
    condition     = length(output.data_lake_bucket_names) == 2 && output.storage_bucket_name == null && length(aws_ecr_repository.this) == 0
    error_message = "A data platform gets data-lake buckets only."
  }
}

run "type_ml_platform" {
  command = plan

  variables {
    infrastructure_type = "ml-platform"
  }

  assert {
    condition     = length(aws_s3_bucket.this) == 2 && length(aws_ecr_repository.this) == 1
    error_message = "An ML platform gets data-lake buckets and a container registry."
  }
}

run "type_container_platform" {
  command = plan

  variables {
    infrastructure_type = "container-platform"
  }

  assert {
    condition     = aws_ecr_repository.this[0].name == "acme-dev" && length(aws_s3_bucket.this) == 0
    error_message = "A container platform gets a container registry."
  }
}

run "type_serverless_platform" {
  command = plan

  variables {
    infrastructure_type = "serverless-platform"
  }

  assert {
    condition     = length(aws_ecr_repository.this) == 1 && length(aws_route53_zone.private) == 0
    error_message = "A serverless platform gets a container registry."
  }
}

run "type_networking_foundation" {
  command = plan

  variables {
    infrastructure_type = "networking-foundation"
  }

  assert {
    condition     = output.private_dns_zone_name == "acme-dev.internal" && length(aws_ecr_repository.this) == 0
    error_message = "A networking foundation gets a private DNS zone."
  }
}

# -----------------------------------------------------------------------------
# CDN and WAF
# -----------------------------------------------------------------------------

run "cdn_with_waf" {
  command = plan

  variables {
    enable_storage = true
    enable_cdn     = true
    enable_waf     = true
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this) == 1 && length(aws_cloudfront_origin_access_control.this) == 1
    error_message = "The CDN must read the bucket through origin access control."
  }

  assert {
    condition     = aws_wafv2_web_acl.this[0].scope == "CLOUDFRONT" && aws_wafv2_web_acl.this[0].region == "us-east-1"
    error_message = "The web ACL of a CDN is CloudFront-scoped in us-east-1."
  }

  assert {
    condition     = aws_cloudfront_distribution.this[0].price_class == "PriceClass_All"
    error_message = "Without cost optimisation the CDN uses every edge location."
  }
}

run "cdn_without_waf" {
  command = plan

  variables {
    enable_storage = true
    enable_cdn     = true
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this) == 1 && length(aws_wafv2_web_acl.this) == 0 && output.waf_id == null
    error_message = "A CDN without WAF must not create a web ACL."
  }

  assert {
    condition     = aws_cloudfront_distribution.this[0].web_acl_id == null
    error_message = "A CDN without WAF has no web ACL attached."
  }
}

run "waf_without_cdn" {
  command = plan

  variables {
    enable_waf        = true
    enable_monitoring = true
    enable_alerting   = true
  }

  assert {
    condition     = aws_wafv2_web_acl.this[0].scope == "REGIONAL" && aws_wafv2_web_acl.this[0].region == "eu-west-2"
    error_message = "Without a CDN the web ACL is regional in the primary region."
  }

  assert {
    condition     = aws_cloudwatch_log_group.waf[0].name == "aws-waf-logs-acme-dev" && aws_cloudwatch_log_group.waf[0].region == "eu-west-2"
    error_message = "WAF logs go to a log group in the region of the web ACL."
  }

  assert {
    condition     = contains(keys(aws_cloudwatch_metric_alarm.this), "waf-blocked-requests") && length(aws_sns_topic.global_alerts) == 0
    error_message = "A regional WAF is alarmed in the primary region."
  }
}

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------

run "autoscaling_off" {
  command = plan

  variables {
    enable_kubernetes = true
    node_size         = "large"
  }

  assert {
    condition = (
      aws_eks_node_group.this[0].scaling_config[0].min_size == 2 &&
      aws_eks_node_group.this[0].scaling_config[0].max_size == 2 &&
      aws_eks_node_group.this[0].scaling_config[0].desired_size == 2
    )
    error_message = "Without autoscaling the node group is fixed at min_nodes."
  }

  assert {
    condition     = length(aws_iam_role.cluster_autoscaler) == 0 && output.cluster_autoscaler_role_arn == null
    error_message = "Without autoscaling there is no cluster autoscaler role."
  }

  assert {
    condition     = aws_eks_node_group.this[0].instance_types == tolist(["c6i.2xlarge"])
    error_message = "node_size large maps to 8 vCPU / 16 GB instances."
  }

  assert {
    condition     = length(aws_eks_cluster.this[0].encryption_config) == 0 && length(aws_eks_cluster.this[0].enabled_cluster_log_types) == 0
    error_message = "Without KMS and monitoring the cluster has no key and no control-plane logs."
  }
}

run "kubernetes_public_api_allow_list" {
  command = plan

  variables {
    enable_kubernetes            = true
    kubernetes_version           = "1.34"
    kubernetes_api_allowed_cidrs = ["203.0.113.0/24"]
  }

  assert {
    condition = (
      aws_eks_cluster.this[0].vpc_config[0].endpoint_public_access &&
      aws_eks_cluster.this[0].vpc_config[0].public_access_cidrs == toset(["203.0.113.0/24"]) &&
      aws_eks_cluster.this[0].version == "1.34"
    )
    error_message = "The API is public for the allowed CIDRs only and uses the requested version."
  }
}

# -----------------------------------------------------------------------------
# Resilience and observability on their own
# -----------------------------------------------------------------------------

run "disaster_recovery_copies_database_backups" {
  command = plan

  variables {
    secondary_region         = "eu-central-1"
    enable_disaster_recovery = true
    enable_database          = true
    enable_storage           = true
  }

  assert {
    condition = (
      length(aws_backup_plan.this) == 1 &&
      aws_backup_vault.secondary[0].region == "eu-central-1" &&
      aws_db_instance.this[0].tags["BackupPlan"] == "acme-dev"
    )
    error_message = "Disaster recovery must copy database backups to the secondary region."
  }

  assert {
    condition     = aws_s3_bucket.replica["storage"].region == "eu-central-1" && length(aws_s3_bucket_replication_configuration.this) == 1
    error_message = "Disaster recovery must replicate the storage bucket to the secondary region."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.replica["storage"].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "Without KMS the replica uses S3-managed encryption."
  }
}

run "disaster_recovery_requires_secondary_region" {
  command = plan

  variables {
    enable_disaster_recovery = true
  }

  expect_failures = [var.secondary_region]
}

run "kubernetes_without_network_fails" {
  command = plan

  variables {
    enable_networking = false
    enable_kubernetes = true
  }

  expect_failures = [aws_eks_cluster.this]
}

run "private_dns_without_network_fails" {
  command = plan

  variables {
    enable_networking   = false
    infrastructure_type = "networking-foundation"
  }

  expect_failures = [aws_route53_zone.private]
}

run "cdn_requires_storage" {
  command = plan

  variables {
    enable_cdn = true
  }

  expect_failures = [var.enable_cdn]
}

# Seven years (SOX): every log group keeps its logs that long itself.
run "log_retention_seven_years" {
  command = plan

  variables {
    log_retention_days        = 2557
    enable_monitoring         = true
    require_flow_logs         = true
    enable_kubernetes         = true
    enable_database           = true
    enable_storage            = true
    enable_cdn                = true
    enable_waf                = true
    enable_managed_prometheus = true
  }

  assert {
    condition = (
      aws_cloudwatch_log_group.central[0].retention_in_days == 2557 &&
      aws_cloudwatch_log_group.cluster[0].retention_in_days == 2557 &&
      aws_cloudwatch_log_group.cdn[0].retention_in_days == 2557 &&
      aws_cloudwatch_log_group.waf[0].retention_in_days == 2557 &&
      aws_cloudwatch_log_group.prometheus[0].retention_in_days == 2557 &&
      alltrue([for group in aws_cloudwatch_log_group.rds : group.retention_in_days == 2557])
    )
    error_message = "Every log group must keep logs for the full 2557 days."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.rds) == 2 && aws_flow_log.this[0].log_destination_type == "cloud-watch-logs"
    error_message = "Database logs and flow logs must be wired to CloudWatch Logs."
  }
}

# Six years (HIPAA), on the log group flow logs get when monitoring is off.
run "log_retention_six_years" {
  command = plan

  variables {
    log_retention_days = 2192
    require_flow_logs  = true
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 2192
    error_message = "The flow log group must keep logs for the full 2192 days."
  }
}

run "prometheus_without_cluster" {
  command = plan

  variables {
    enable_managed_prometheus = true
    enable_managed_grafana    = false
  }

  assert {
    condition     = length(aws_prometheus_workspace.this) == 1 && length(aws_prometheus_scraper.this) == 0 && length(aws_grafana_workspace.this) == 0
    error_message = "Without a cluster there is a workspace but no scraper; Grafana can be switched off."
  }
}
