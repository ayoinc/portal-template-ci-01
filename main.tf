# sample-infrastructure
#
# One module per cloud implements the whole stack; the settings in
# terraform.tfvars and environments/ decide what it creates.

# -----------------------------------------------------------------------------
# AWS
# -----------------------------------------------------------------------------

module "aws" {
  source = "./modules/aws"

  name_prefix         = local.name_prefix
  environment         = var.environment
  region              = var.aws_region
  secondary_region    = var.aws_secondary_region
  tags                = local.tags
  infrastructure_type = var.infrastructure_type

  enable_networking           = var.enable_networking
  network_cidr                = var.aws_network_cidr
  existing_network            = var.aws_existing_network
  allowed_ingress_cidrs       = var.allowed_ingress_cidrs
  enable_security_group_rules = var.enable_security_group_rules
  require_flow_logs           = local.compliance.require_flow_logs

  enable_kubernetes            = var.enable_kubernetes
  kubernetes_version           = var.kubernetes_version
  kubernetes_api_allowed_cidrs = var.kubernetes_api_allowed_cidrs
  node_size                    = var.node_size
  enable_autoscaling           = var.enable_autoscaling
  min_nodes                    = var.min_nodes
  max_nodes                    = var.max_nodes

  enable_database = var.enable_database
  database_type   = var.database_type
  enable_storage  = local.enable_storage
  enable_cdn      = var.enable_cdn

  enable_waf                  = var.enable_waf
  enable_secrets_manager      = var.enable_secrets_manager
  enable_kms                  = local.enable_kms
  enable_backup               = local.enable_backup
  require_deletion_protection = local.require_deletion_protection

  enable_monitoring         = var.enable_monitoring
  enable_managed_prometheus = local.enable_managed_prometheus
  enable_alerting           = var.enable_alerting
  alert_email               = var.alert_email
  log_retention_days        = local.log_retention_days

  enable_disaster_recovery = var.enable_disaster_recovery
  enable_cost_optimization = var.enable_cost_optimization
}
