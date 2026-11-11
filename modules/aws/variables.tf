# -----------------------------------------------------------------------------
# Identity
# -----------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for all resource names: up to 24 lowercase letters, digits and hyphens, starting with a letter."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,22}[a-z0-9])?$", var.name_prefix)) && !strcontains(var.name_prefix, "--")
    error_message = "name_prefix must be 1-24 characters of lowercase letters, digits and single hyphens, start with a letter and not end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment: development, staging or production."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging or production."
  }
}

variable "region" {
  description = "Primary AWS region. Must be the region of the default aws provider passed to this module."
  type        = string
}

variable "secondary_region" {
  description = "Disaster-recovery AWS region. Must be the region of the aws.secondary provider. Required when enable_disaster_recovery is true."
  type        = string
  default     = null

  validation {
    condition     = !var.enable_disaster_recovery || (var.secondary_region != null && var.secondary_region != var.region)
    error_message = "secondary_region must be set and differ from region when enable_disaster_recovery is true."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}

variable "infrastructure_type" {
  description = "Kind of platform: web-application, data-platform, ml-platform, container-platform, serverless-platform or networking-foundation."
  type        = string

  validation {
    condition = contains([
      "web-application",
      "data-platform",
      "ml-platform",
      "container-platform",
      "serverless-platform",
      "networking-foundation",
    ], var.infrastructure_type)
    error_message = "infrastructure_type must be one of web-application, data-platform, ml-platform, container-platform, serverless-platform, networking-foundation."
  }
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "enable_networking" {
  description = "Create the VPC, subnets and NAT gateways. When false, existing_network is used."
  type        = bool
}

variable "network_cidr" {
  description = "CIDR block of the created VPC, between /16 and /24."
  type        = string

  validation {
    condition     = can(cidrhost(var.network_cidr, 0)) && try(tonumber(split("/", var.network_cidr)[1]) >= 16 && tonumber(split("/", var.network_cidr)[1]) <= 24, false)
    error_message = "network_cidr must be a valid IPv4 CIDR block with a prefix length between /16 and /24."
  }
}

variable "existing_network" {
  description = "VPC and subnets to use when enable_networking is false."
  type = object({
    network_id         = string
    public_subnet_ids  = list(string)
    private_subnet_ids = list(string)
  })
  default = null
}

variable "availability_zone_count" {
  description = "Number of availability zones the created subnets span."
  type        = number
  default     = 2

  validation {
    condition     = contains([2, 3], var.availability_zone_count)
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "allowed_ingress_cidrs" {
  description = "Client CIDR blocks allowed to reach the web tier over HTTPS."
  type        = list(string)
  default     = []
}

variable "enable_security_group_rules" {
  description = "Create tiered web, app and data security groups. When false, data stores accept traffic from the whole VPC CIDR."
  type        = bool
}

variable "app_port" {
  description = "Port the app tier listens on for traffic from the web tier."
  type        = number
  default     = 8080
}

variable "require_flow_logs" {
  description = "Send VPC flow logs to CloudWatch Logs."
  type        = bool
}

variable "private_dns_zone_name" {
  description = "Name of the Route 53 private hosted zone of a networking-foundation stack. Defaults to <name_prefix>.internal."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------

variable "enable_kubernetes" {
  description = "Create an EKS cluster with a managed node group in the private subnets."
  type        = bool
}

variable "kubernetes_version" {
  description = "Kubernetes version of the cluster. Null uses the current EKS default."
  type        = string
  default     = null
}

variable "kubernetes_api_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API over the internet. Empty keeps the API private to the VPC."
  type        = list(string)
  default     = []
}

variable "node_size" {
  description = "Worker node size: small (2 vCPU/4 GB), medium (4/8), large (8/16) or xlarge (16/32)."
  type        = string

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.node_size)
    error_message = "node_size must be small, medium, large or xlarge."
  }
}

variable "enable_autoscaling" {
  description = "Let the node group scale between min_nodes and max_nodes. When false it stays at min_nodes."
  type        = bool
}

variable "min_nodes" {
  description = "Minimum (and initial) number of worker nodes."
  type        = number

  validation {
    condition     = var.min_nodes >= 1 && floor(var.min_nodes) == var.min_nodes
    error_message = "min_nodes must be a whole number of at least 1."
  }
}

variable "max_nodes" {
  description = "Maximum number of worker nodes when autoscaling is enabled."
  type        = number

  validation {
    condition     = var.max_nodes >= var.min_nodes && floor(var.max_nodes) == var.max_nodes
    error_message = "max_nodes must be a whole number greater than or equal to min_nodes."
  }
}

# -----------------------------------------------------------------------------
# Data
# -----------------------------------------------------------------------------

variable "enable_database" {
  description = "Create a managed database."
  type        = bool
}

variable "database_type" {
  description = "Database engine: postgresql or mysql (RDS), mongodb (DocumentDB), redis (ElastiCache) or dynamodb."
  type        = string

  validation {
    condition     = contains(["postgresql", "mysql", "mongodb", "redis", "dynamodb"], var.database_type)
    error_message = "database_type must be one of postgresql, mysql, mongodb, redis, dynamodb."
  }
}

variable "database_engine_version" {
  description = "Engine version of the database. Null uses a current major version of the selected engine."
  type        = string
  default     = null
}

variable "enable_storage" {
  description = "Create a private, versioned, encrypted S3 bucket."
  type        = bool
}

variable "enable_cdn" {
  description = "Serve the storage bucket through CloudFront. Requires enable_storage."
  type        = bool

  validation {
    condition     = !var.enable_cdn || var.enable_storage
    error_message = "enable_cdn requires enable_storage: the CDN serves the storage bucket."
  }
}

variable "cdn_aliases" {
  description = "Custom domain names of the CloudFront distribution. Requires cdn_acm_certificate_arn."
  type        = list(string)
  default     = []
}

variable "cdn_acm_certificate_arn" {
  description = "ARN of an ACM certificate in us-east-1 for cdn_aliases. Null serves the default cloudfront.net domain."
  type        = string
  default     = null

  validation {
    condition     = length(var.cdn_aliases) == 0 || var.cdn_acm_certificate_arn != null
    error_message = "cdn_acm_certificate_arn must be set when cdn_aliases are given."
  }
}

variable "enable_waf" {
  description = "Create a WAF web ACL with AWS managed rule groups. Attached to the CDN when there is one, otherwise regional and exposed as an output."
  type        = bool
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------

variable "enable_secrets_manager" {
  description = "Create a Secrets Manager secret for application configuration and keep generated database credentials in Secrets Manager."
  type        = bool
}

variable "enable_kms" {
  description = "Encrypt storage, databases, secrets and logs with a customer-managed KMS key. When false, AWS-managed encryption is used."
  type        = bool
}

variable "require_deletion_protection" {
  description = "Protect databases, the cluster, keys, vaults and buckets against deletion."
  type        = bool
}

# -----------------------------------------------------------------------------
# Resilience
# -----------------------------------------------------------------------------

variable "enable_backup" {
  description = "Create an AWS Backup vault and plan for the stateful resources and keep database backups for 35 days instead of 7."
  type        = bool
}

variable "enable_disaster_recovery" {
  description = "Replicate object storage and copy database backups to secondary_region."
  type        = bool
}

variable "enable_cost_optimization" {
  description = "Tier object storage and, outside production, use Spot nodes, a single NAT gateway and the smallest database tier."
  type        = bool
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

variable "enable_monitoring" {
  description = "Create the central CloudWatch log group, component logging and a dashboard."
  type        = bool
}

variable "log_retention_days" {
  description = "Retention of logs in days. CloudWatch Logs keeps the log groups themselves for that long, up to ten years, so 7, 30, 90, 365, 2192 (6 years) and 2557 (7 years) apply as given without a separate archive. A value between two periods CloudWatch Logs supports is rounded up to the longer one, never down."
  type        = number

  validation {
    condition     = var.log_retention_days >= 1 && var.log_retention_days <= 3653
    error_message = "log_retention_days must be between 1 and 3653."
  }
}

variable "enable_managed_prometheus" {
  description = "Create an Amazon Managed Service for Prometheus workspace, a scraper for the cluster and an Amazon Managed Grafana workspace."
  type        = bool
}

variable "enable_managed_grafana" {
  description = "Create the Amazon Managed Grafana workspace alongside managed Prometheus. Set to false in regions without Amazon Managed Grafana."
  type        = bool
  default     = true
}

variable "grafana_authentication_providers" {
  description = "Sign-in methods of the Grafana workspace: SAML and/or AWS_SSO. AWS_SSO needs IAM Identity Center enabled in the account."
  type        = list(string)
  default     = ["SAML"]

  validation {
    condition     = length(var.grafana_authentication_providers) > 0 && alltrue([for p in var.grafana_authentication_providers : contains(["SAML", "AWS_SSO"], p)])
    error_message = "grafana_authentication_providers must contain SAML and/or AWS_SSO."
  }
}

variable "enable_alerting" {
  description = "Create an SNS topic and CloudWatch alarms for the components that exist."
  type        = bool
}

variable "alert_email" {
  description = "Email address subscribed to the alert topic. Null creates no subscription."
  type        = string
  default     = null
}
