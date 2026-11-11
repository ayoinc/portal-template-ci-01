locals {
  short_environment = {
    development = "dev"
    staging     = "stg"
    production  = "prod"
  }[var.environment]

  # At most 24 characters, so that every cloud accepts names built from it.
  name_prefix = "${trimsuffix(substr(var.name, 0, 19), "-")}-${local.short_environment}"

  # Baseline each compliance framework adds to the settings of the stack.
  compliance_baselines = {
    none = {
      min_log_retention_days      = 0
      customer_managed_keys       = false
      backups                     = false
      require_deletion_protection = false
      require_flow_logs           = false
    }
    cis = {
      min_log_retention_days      = 365
      customer_managed_keys       = false
      backups                     = false
      require_deletion_protection = false
      require_flow_logs           = true
    }
    pci-dss = {
      min_log_retention_days      = 365
      customer_managed_keys       = true
      backups                     = true
      require_deletion_protection = true
      require_flow_logs           = true
    }
    hipaa = {
      min_log_retention_days      = 2192
      customer_managed_keys       = true
      backups                     = true
      require_deletion_protection = true
      require_flow_logs           = true
    }
    sox = {
      min_log_retention_days      = 2557
      customer_managed_keys       = true
      backups                     = true
      require_deletion_protection = true
      require_flow_logs           = false
    }
    gdpr = {
      min_log_retention_days      = 0
      customer_managed_keys       = true
      backups                     = true
      require_deletion_protection = false
      require_flow_logs           = false
    }
  }

  compliance = local.compliance_baselines[var.compliance_framework]

  # Settings after the compliance baseline and the dependencies between
  # features are applied.
  log_retention_days          = max(var.log_retention_days, local.compliance.min_log_retention_days)
  enable_kms                  = var.enable_kms || local.compliance.customer_managed_keys
  enable_backup               = var.enable_backup || local.compliance.backups
  enable_storage              = var.enable_storage || var.enable_cdn
  require_deletion_protection = local.compliance.require_deletion_protection || var.environment == "production"
  enable_managed_prometheus   = var.enable_monitoring && var.monitoring_solution == "prometheus-grafana"

  tags = merge(
    var.tags,
    {
      Project            = var.name
      Environment        = var.environment
      Owner              = var.owner
      InfrastructureType = var.infrastructure_type
      ManagedBy          = "terraform"
    },
    var.compliance_framework == "none" ? {} : { Compliance = var.compliance_framework },
  )
}
