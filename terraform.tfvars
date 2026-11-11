# Settings chosen when this stack was created; they apply to every
# environment. Environment-specific settings are in environments/<name>.tfvars
# and take precedence. Change values here and push to apply the change.
name                = "sample-infrastructure"
owner               = "group:default/platform-team"
infrastructure_type = "web-application"

aws_region           = "us-east-1"
aws_secondary_region = "us-west-2"

# Network
enable_networking           = true
enable_security_group_rules = true

# Kubernetes
enable_kubernetes  = false
node_size          = "medium"
enable_autoscaling = true
min_nodes          = 2
max_nodes          = 10

# Data
enable_database = true
database_type   = "postgresql"
enable_storage  = true
enable_cdn      = false

# Security and compliance
enable_waf             = false
enable_secrets_manager = true
enable_kms             = true
enable_backup          = true
compliance_framework   = "none"

# Monitoring
enable_monitoring   = true
monitoring_solution = "native"
enable_alerting     = true
log_retention_days  = 30

# Resilience and cost
enable_disaster_recovery = false
enable_cost_optimization = true
