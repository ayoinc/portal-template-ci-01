locals {
  # Flow logs go to the central log group, or to their own when monitoring is off.
  flow_log_group_arn = var.enable_monitoring ? one(aws_cloudwatch_log_group.central[*].arn) : one(aws_cloudwatch_log_group.flow_logs[*].arn)

  # CloudFront and its WAF report metrics in the global region only, so their
  # alarms and the topic the alarms publish to live there.
  create_global_alerts = var.enable_alerting && local.create_cdn

  # ElastiCache reports per node; this is the primary node of the group.
  redis_primary_node = "${var.name_prefix}-001"

  # ---------------------------------------------------------------------------
  # Alarms of the primary region, for the components that exist
  # ---------------------------------------------------------------------------

  alarms = merge(
    { for name, alarm in {
      database-cpu = {
        description         = "CPU of the database above 80% for 15 minutes"
        namespace           = "AWS/RDS"
        metric_name         = "CPUUtilization"
        dimensions          = { DBInstanceIdentifier = var.name_prefix }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 80
        period              = 300
        evaluation_periods  = 3
      }
      database-storage = {
        description         = "Less than 2 GiB of database storage left"
        namespace           = "AWS/RDS"
        metric_name         = "FreeStorageSpace"
        dimensions          = { DBInstanceIdentifier = var.name_prefix }
        statistic           = "Average"
        comparison_operator = "LessThanThreshold"
        threshold           = 2 * 1024 * 1024 * 1024
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if local.create_rds },
    { for name, alarm in {
      database-cpu = {
        description         = "CPU of the database cluster above 80% for 15 minutes"
        namespace           = "AWS/DocDB"
        metric_name         = "CPUUtilization"
        dimensions          = { DBClusterIdentifier = var.name_prefix }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 80
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if local.create_docdb },
    { for name, alarm in {
      database-cpu = {
        description         = "Redis engine CPU above 80% for 15 minutes"
        namespace           = "AWS/ElastiCache"
        metric_name         = "EngineCPUUtilization"
        dimensions          = { CacheClusterId = local.redis_primary_node }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 80
        period              = 300
        evaluation_periods  = 3
      }
      database-memory = {
        description         = "Redis memory use above 80% for 15 minutes"
        namespace           = "AWS/ElastiCache"
        metric_name         = "DatabaseMemoryUsagePercentage"
        dimensions          = { CacheClusterId = local.redis_primary_node }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 80
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if local.create_redis },
    { for name, alarm in {
      database-read-throttles = {
        description         = "Reads on the DynamoDB table are throttled"
        namespace           = "AWS/DynamoDB"
        metric_name         = "ReadThrottleEvents"
        dimensions          = { TableName = var.name_prefix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
      database-write-throttles = {
        description         = "Writes on the DynamoDB table are throttled"
        namespace           = "AWS/DynamoDB"
        metric_name         = "WriteThrottleEvents"
        dimensions          = { TableName = var.name_prefix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if local.create_dynamodb },
    { for name, alarm in {
      cluster-api-errors = {
        description         = "The Kubernetes API server answers with 5xx errors"
        namespace           = "AWS/EKS"
        metric_name         = "apiserver_request_total_5XX"
        dimensions          = { ClusterName = var.name_prefix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 10
        period              = 300
        evaluation_periods  = 3
      }
      cluster-unschedulable-pods = {
        description         = "Pods have been unschedulable for 15 minutes"
        namespace           = "AWS/EKS"
        metric_name         = "scheduler_pending_pods_UNSCHEDULABLE"
        dimensions          = { ClusterName = var.name_prefix }
        statistic           = "Maximum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if var.enable_kubernetes },
    { for name, alarm in {
      storage-errors = {
        description         = "The storage bucket answers with 5xx errors"
        namespace           = "AWS/S3"
        metric_name         = "5xxErrors"
        dimensions          = { BucketName = local.bucket_names["storage"], FilterId = local.bucket_metric_filter }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if var.enable_storage },
    { for name, alarm in {
      storage-replication = {
        description         = "Objects of the storage bucket fail to replicate to the disaster-recovery region"
        namespace           = "AWS/S3"
        metric_name         = "OperationsFailedReplication"
        dimensions          = { SourceBucket = local.bucket_names["storage"], DestinationBucket = local.replica_bucket_names["storage"], RuleId = local.replication_rule_id }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if var.enable_storage && var.enable_disaster_recovery },
    { for name, alarm in {
      waf-blocked-requests = {
        description         = "The WAF blocks more than 1000 requests in five minutes"
        namespace           = "AWS/WAFV2"
        metric_name         = "BlockedRequests"
        dimensions          = { WebACL = local.waf_name, Rule = "ALL", Region = var.region }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 1000
        period              = 300
        evaluation_periods  = 1
      }
    } : name => alarm if local.create_regional_waf },
    { for name, alarm in {
      backup-failures = {
        description         = "A backup job failed"
        namespace           = "AWS/Backup"
        metric_name         = "NumberOfBackupJobsFailed"
        dimensions          = { BackupVaultName = var.name_prefix }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 0
        period              = 3600
        evaluation_periods  = 1
      }
    } : name => alarm if local.create_backup },
  )

  # ---------------------------------------------------------------------------
  # Alarms of the global region: the CDN and its WAF
  # ---------------------------------------------------------------------------

  global_alarms = merge(
    { for name, alarm in {
      cdn-errors = {
        description         = "More than 5% of the CDN responses are 5xx errors"
        namespace           = "AWS/CloudFront"
        metric_name         = "5xxErrorRate"
        dimensions          = { DistributionId = one(aws_cloudfront_distribution.this[*].id), Region = "Global" }
        statistic           = "Average"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 5
        period              = 300
        evaluation_periods  = 3
      }
    } : name => alarm if local.create_cdn },
    { for name, alarm in {
      waf-blocked-requests = {
        description         = "The WAF blocks more than 1000 requests in five minutes"
        namespace           = "AWS/WAFV2"
        metric_name         = "BlockedRequests"
        dimensions          = { WebACL = local.waf_name, Rule = "ALL" }
        statistic           = "Sum"
        comparison_operator = "GreaterThanThreshold"
        threshold           = 1000
        period              = 300
        evaluation_periods  = 1
      }
    } : name => alarm if local.create_global_waf },
  )

  # ---------------------------------------------------------------------------
  # Dashboard panels, for the components that exist
  # ---------------------------------------------------------------------------

  dashboard_panels = [
    {
      enabled = var.enable_networking
      title   = "NAT gateways: bytes to the internet"
      region  = var.region
      stat    = "Sum"
      metrics = [for nat in aws_nat_gateway.this : ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", nat.id]]
    },
    {
      enabled = var.enable_kubernetes
      title   = "Cluster: node CPU and memory (%)"
      region  = var.region
      stat    = "Average"
      metrics = [
        ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.name_prefix],
        ["ContainerInsights", "node_memory_utilization", "ClusterName", var.name_prefix],
      ]
    },
    {
      enabled = var.enable_kubernetes
      title   = "Cluster: API server requests"
      region  = var.region
      stat    = "Sum"
      metrics = [
        ["AWS/EKS", "apiserver_request_total", "ClusterName", var.name_prefix],
        ["AWS/EKS", "apiserver_request_total_5XX", "ClusterName", var.name_prefix],
      ]
    },
    {
      enabled = local.create_rds
      title   = "Database: CPU (%) and connections"
      region  = var.region
      stat    = "Average"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.name_prefix],
        ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.name_prefix],
      ]
    },
    {
      enabled = local.create_docdb
      title   = "Database: CPU (%) and connections"
      region  = var.region
      stat    = "Average"
      metrics = [
        ["AWS/DocDB", "CPUUtilization", "DBClusterIdentifier", var.name_prefix],
        ["AWS/DocDB", "DatabaseConnections", "DBClusterIdentifier", var.name_prefix],
      ]
    },
    {
      enabled = local.create_redis
      title   = "Redis: engine CPU and memory (%)"
      region  = var.region
      stat    = "Average"
      metrics = [
        ["AWS/ElastiCache", "EngineCPUUtilization", "CacheClusterId", local.redis_primary_node],
        ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "CacheClusterId", local.redis_primary_node],
      ]
    },
    {
      enabled = local.create_dynamodb
      title   = "DynamoDB: consumed capacity"
      region  = var.region
      stat    = "Sum"
      metrics = [
        ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.name_prefix],
        ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.name_prefix],
      ]
    },
    {
      enabled = var.enable_storage
      title   = "Storage: requests and errors"
      region  = var.region
      stat    = "Sum"
      metrics = [
        ["AWS/S3", "AllRequests", "BucketName", local.bucket_names["storage"], "FilterId", local.bucket_metric_filter],
        ["AWS/S3", "4xxErrors", "BucketName", local.bucket_names["storage"], "FilterId", local.bucket_metric_filter],
        ["AWS/S3", "5xxErrors", "BucketName", local.bucket_names["storage"], "FilterId", local.bucket_metric_filter],
      ]
    },
    {
      enabled = local.create_cdn
      title   = "CDN: requests"
      region  = local.global_region
      stat    = "Sum"
      metrics = [
        ["AWS/CloudFront", "Requests", "DistributionId", one(aws_cloudfront_distribution.this[*].id), "Region", "Global"],
      ]
    },
    {
      enabled = local.create_global_waf
      title   = "WAF: allowed and blocked requests"
      region  = local.global_region
      stat    = "Sum"
      metrics = [
        ["AWS/WAFV2", "AllowedRequests", "WebACL", local.waf_name, "Rule", "ALL"],
        ["AWS/WAFV2", "BlockedRequests", "WebACL", local.waf_name, "Rule", "ALL"],
      ]
    },
    {
      enabled = local.create_regional_waf
      title   = "WAF: allowed and blocked requests"
      region  = var.region
      stat    = "Sum"
      metrics = [
        ["AWS/WAFV2", "AllowedRequests", "WebACL", local.waf_name, "Rule", "ALL", "Region", var.region],
        ["AWS/WAFV2", "BlockedRequests", "WebACL", local.waf_name, "Rule", "ALL", "Region", var.region],
      ]
    },
  ]

  dashboard_widgets = concat(
    [{
      type   = "text"
      width  = 24
      height = 2
      properties = {
        markdown = join("\n", [
          "# ${var.name_prefix}",
          "Environment **${var.environment}**, type **${var.infrastructure_type}**, region **${var.region}**${var.enable_disaster_recovery ? ", disaster recovery in **${var.secondary_region}**" : ""}.",
        ])
      }
    }],
    [for panel in local.dashboard_panels : {
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = panel.title
        region  = panel.region
        view    = "timeSeries"
        stacked = false
        period  = 300
        stat    = panel.stat
        metrics = panel.metrics
      }
    } if panel.enabled],
    [{
      type   = "log"
      width  = 24
      height = 8
      properties = {
        title  = "Latest entries of the central log group"
        region = var.region
        view   = "table"
        query  = "SOURCE '${local.central_log_group_name}' | fields @timestamp, @logStream, @message | sort @timestamp desc | limit 50"
      }
    }],
  )

  central_log_group_name = "/${var.name_prefix}/platform"
}

# -----------------------------------------------------------------------------
# Log groups
# -----------------------------------------------------------------------------

# Central destination: flow logs arrive here and applications may write to it.
resource "aws_cloudwatch_log_group" "central" {
  count = var.enable_monitoring ? 1 : 0

  name              = local.central_log_group_name
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = local.create_flow_logs && !var.enable_monitoring ? 1 : 0

  name              = "/${var.name_prefix}/vpc-flow-logs"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Dashboard
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enable_monitoring ? 1 : 0

  dashboard_name = var.name_prefix
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}

# -----------------------------------------------------------------------------
# Alerting in the primary region
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  count = var.enable_alerting ? 1 : 0

  name              = "${var.name_prefix}-alerts"
  display_name      = "Alerts of ${var.name_prefix}"
  kms_master_key_id = local.kms_key_arn

  tags = var.tags
}

resource "aws_sns_topic_policy" "alerts" {
  count = var.enable_alerting ? 1 : 0

  arn = aws_sns_topic.alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudWatchAlarmsPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.${local.dns_suffix}" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.alerts[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "alert_email" {
  count = var.enable_alerting && var.alert_email != null ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = { for name, alarm in local.alarms : name => alarm if var.enable_alerting }

  alarm_name          = "${var.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Alerting in the global region
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "global_alerts" {
  count = local.create_global_alerts ? 1 : 0

  region            = local.global_region
  name              = "${var.name_prefix}-edge-alerts"
  display_name      = "CDN alerts of ${var.name_prefix}"
  kms_master_key_id = local.global_kms_key_arn

  tags = var.tags
}

resource "aws_sns_topic_policy" "global_alerts" {
  count = local.create_global_alerts ? 1 : 0

  region = local.global_region
  arn    = aws_sns_topic.global_alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudWatchAlarmsPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.${local.dns_suffix}" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.global_alerts[0].arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "global_alert_email" {
  count = local.create_global_alerts && var.alert_email != null ? 1 : 0

  region    = local.global_region
  topic_arn = aws_sns_topic.global_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "global" {
  for_each = { for name, alarm in local.global_alarms : name => alarm if local.create_global_alerts }

  region              = local.global_region
  alarm_name          = "${var.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  dimensions          = each.value.dimensions
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison_operator
  threshold           = each.value.threshold
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.global_alerts[0].arn]
  ok_actions    = [aws_sns_topic.global_alerts[0].arn]

  tags = var.tags
}
