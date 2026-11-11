locals {
  create_prometheus_scraper = var.enable_managed_prometheus && var.enable_kubernetes
  create_grafana            = var.enable_managed_prometheus && var.enable_managed_grafana
}

# -----------------------------------------------------------------------------
# Amazon Managed Service for Prometheus
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "prometheus" {
  count = var.enable_managed_prometheus && var.enable_monitoring ? 1 : 0

  name              = "/aws/vendedlogs/prometheus/${var.name_prefix}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.kms_key_arn

  tags = var.tags
}

# Without a cluster the workspace is fed through remote write: its endpoint
# followed by api/v1/remote_write, signed with SigV4.
resource "aws_prometheus_workspace" "this" {
  count = var.enable_managed_prometheus ? 1 : 0

  alias       = var.name_prefix
  kms_key_arn = local.kms_key_arn

  dynamic "logging_configuration" {
    for_each = aws_cloudwatch_log_group.prometheus[*].arn

    content {
      log_group_arn = "${logging_configuration.value}:*"
    }
  }

  tags = var.tags
}

data "aws_prometheus_default_scraper_configuration" "this" {
  count = local.create_prometheus_scraper ? 1 : 0
}

# Agentless collector: scrapes the cluster from inside its subnets and writes
# to the workspace. It reaches the API server and the nodes as a member of the
# cluster security group.
resource "aws_prometheus_scraper" "this" {
  count = local.create_prometheus_scraper ? 1 : 0

  alias                = var.name_prefix
  scrape_configuration = data.aws_prometheus_default_scraper_configuration.this[0].configuration

  source {
    eks {
      cluster_arn        = aws_eks_cluster.this[0].arn
      subnet_ids         = local.private_subnet_ids
      security_group_ids = [aws_eks_cluster.this[0].vpc_config[0].cluster_security_group_id]
    }
  }

  destination {
    amp {
      workspace_arn = aws_prometheus_workspace.this[0].arn
    }
  }

  tags = var.tags

  # There is nothing to scrape before the nodes have joined.
  depends_on = [aws_eks_node_group.this]
}

# -----------------------------------------------------------------------------
# Amazon Managed Grafana
# -----------------------------------------------------------------------------

resource "aws_iam_role" "grafana" {
  count = local.create_grafana ? 1 : 0

  name = "${var.name_prefix}-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.${local.dns_suffix}" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  tags = var.tags
}

# Lets Grafana query the Prometheus workspace of this stack and nothing else.
resource "aws_iam_role_policy" "grafana_prometheus" {
  count = local.create_grafana ? 1 : 0

  name = "query-prometheus"
  role = aws_iam_role.grafana[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:DescribeWorkspace",
        "aps:QueryMetrics",
        "aps:GetLabels",
        "aps:GetSeries",
        "aps:GetMetricMetadata",
      ]
      Resource = aws_prometheus_workspace.this[0].arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  count = local.create_grafana && var.enable_monitoring ? 1 : 0

  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess"
}

resource "aws_grafana_workspace" "this" {
  count = local.create_grafana ? 1 : 0

  name                     = var.name_prefix
  description              = "Dashboards of ${var.name_prefix}"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = var.grafana_authentication_providers
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana[0].arn
  data_sources             = var.enable_monitoring ? ["PROMETHEUS", "CLOUDWATCH"] : ["PROMETHEUS"]

  tags = var.tags

  depends_on = [aws_iam_role_policy.grafana_prometheus]
}
