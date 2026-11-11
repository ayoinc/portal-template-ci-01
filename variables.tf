variable "name" {
  description = "Name of the infrastructure stack."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*[a-z0-9]$", var.name))
    error_message = "name must be lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "environment" {
  description = "Environment: development, staging or production. Set by the environment files under environments/."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging or production."
  }
}

variable "owner" {
  description = "Owner of the stack; added to every resource as a tag."
  type        = string
}

variable "infrastructure_type" {
  description = "Infrastructure pattern: web-application, data-platform, ml-platform, container-platform, serverless-platform or networking-foundation."
  type        = string

  validation {
    condition     = contains(["web-application", "data-platform", "ml-platform", "container-platform", "serverless-platform", "networking-foundation"], var.infrastructure_type)
    error_message = "infrastructure_type must be one of web-application, data-platform, ml-platform, container-platform, serverless-platform, networking-foundation."
  }
}

variable "tags" {
  description = "Additional tags for all resources."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

variable "enable_networking" {
  description = "Create the network. When false, the existing network of each cloud must be given."
  type        = bool
  default     = true
}

variable "allowed_ingress_cidrs" {
  description = "Client CIDR blocks allowed to reach the web tier."
  type        = list(string)
  default     = []
}

variable "enable_security_group_rules" {
  description = "Create tiered security groups (web, app, data). When false, data stores accept traffic from the whole network range."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------

variable "enable_kubernetes" {
  description = "Create a managed Kubernetes cluster."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "Kubernetes version. Null uses the current default of the cloud."
  type        = string
  default     = null
}

variable "kubernetes_api_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the Kubernetes API from outside the network. Empty keeps the API private."
  type        = list(string)
  default     = []
}

variable "node_size" {
  description = "Node size: small (2 vCPU, 4 GB), medium (4, 8), large (8, 16) or xlarge (16, 32)."
  type        = string
  default     = "medium"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.node_size)
    error_message = "node_size must be small, medium, large or xlarge."
  }
}

variable "enable_autoscaling" {
  description = "Scale the node count between min_nodes and max_nodes. When false the cluster keeps min_nodes."
  type        = bool
  default     = true
}

variable "min_nodes" {
  description = "Minimum number of nodes."
  type        = number
  default     = 2
}

variable "max_nodes" {
  description = "Maximum number of nodes."
  type        = number
  default     = 10

  validation {
    condition     = var.max_nodes >= var.min_nodes
    error_message = "max_nodes must not be smaller than min_nodes."
  }
}

# -----------------------------------------------------------------------------
# Data
# -----------------------------------------------------------------------------

variable "enable_database" {
  description = "Create a managed database."
  type        = bool
  default     = false
}

variable "database_type" {
  description = "Database engine; the supported values depend on the cloud."
  type        = string
  default     = "postgresql"
}

variable "enable_storage" {
  description = "Create object storage."
  type        = bool
  default     = true
}

variable "enable_cdn" {
  description = "Create a CDN in front of the object storage, which is then created too."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Security and compliance
# -----------------------------------------------------------------------------

variable "enable_waf" {
  description = "Create a web application firewall policy with managed rules."
  type        = bool
  default     = false
}

variable "enable_secrets_manager" {
  description = "Create a secret store; generated database credentials are kept there."
  type        = bool
  default     = true
}

variable "enable_kms" {
  description = "Encrypt with a customer-managed key. Some compliance frameworks switch this on."
  type        = bool
  default     = true
}

variable "enable_backup" {
  description = "Create the backup service and keep database backups for 35 days. Some compliance frameworks switch this on."
  type        = bool
  default     = true
}

variable "compliance_framework" {
  description = "Compliance baseline applied to the stack: none, cis, pci-dss, hipaa, sox or gdpr."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "cis", "pci-dss", "hipaa", "sox", "gdpr"], var.compliance_framework)
    error_message = "compliance_framework must be none, cis, pci-dss, hipaa, sox or gdpr."
  }
}

# -----------------------------------------------------------------------------
# Monitoring
# -----------------------------------------------------------------------------

variable "enable_monitoring" {
  description = "Create the log destination, diagnostics and dashboard."
  type        = bool
  default     = true
}

variable "monitoring_solution" {
  description = "Monitoring platform: native, prometheus-grafana, elastic-stack, datadog or new-relic."
  type        = string
  default     = "native"

  validation {
    condition     = contains(["native", "prometheus-grafana", "elastic-stack", "datadog", "new-relic"], var.monitoring_solution)
    error_message = "monitoring_solution must be native, prometheus-grafana, elastic-stack, datadog or new-relic."
  }
}

variable "enable_alerting" {
  description = "Create the notification target and alert rules."
  type        = bool
  default     = true
}

variable "alert_email" {
  description = "Email address that receives alerts. Null creates the notification target without a subscriber."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Days to keep logs. A compliance framework can raise it."
  type        = number
  default     = 30

  validation {
    condition     = contains([7, 30, 90, 365], var.log_retention_days)
    error_message = "log_retention_days must be 7, 30, 90 or 365."
  }
}

# -----------------------------------------------------------------------------
# Resilience and cost
# -----------------------------------------------------------------------------

variable "enable_disaster_recovery" {
  description = "Replicate object storage and database backups to the secondary region."
  type        = bool
  default     = false
}

variable "enable_cost_optimization" {
  description = "Storage lifecycle tiering; outside production also spot nodes, a single NAT and the smallest database tier."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AWS
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region of the stack."
  type        = string
}

variable "aws_secondary_region" {
  description = "AWS region for disaster recovery."
  type        = string
}

variable "aws_network_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "aws_existing_network" {
  description = "Existing VPC and subnets to use when enable_networking is false."
  type = object({
    network_id         = string
    public_subnet_ids  = list(string)
    private_subnet_ids = list(string)
  })
  default = null
}
