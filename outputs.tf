output "name_prefix" {
  description = "Prefix of every resource name: the stack name and the short environment."
  value       = local.name_prefix
}

output "effective_settings" {
  description = "Settings after the compliance baseline and the dependencies between features are applied."
  value = {
    compliance_framework        = var.compliance_framework
    log_retention_days          = local.log_retention_days
    enable_kms                  = local.enable_kms
    enable_backup               = local.enable_backup
    enable_storage              = local.enable_storage
    require_deletion_protection = local.require_deletion_protection
    require_flow_logs           = local.compliance.require_flow_logs
  }
}

# -----------------------------------------------------------------------------
# AWS
# -----------------------------------------------------------------------------

output "aws_network_id" {
  description = "ID of the network. Null or empty when it is not created."
  value       = module.aws.network_id
}

output "aws_public_subnet_ids" {
  description = "IDs of the public subnets. Null or empty when it is not created."
  value       = module.aws.public_subnet_ids
}

output "aws_private_subnet_ids" {
  description = "IDs of the private subnets. Null or empty when it is not created."
  value       = module.aws.private_subnet_ids
}

output "aws_kubernetes_cluster_name" {
  description = "Name of the Kubernetes cluster. Null or empty when it is not created."
  value       = module.aws.kubernetes_cluster_name
}

output "aws_database_endpoint" {
  description = "Endpoint of the database. Null or empty when it is not created."
  value       = module.aws.database_endpoint
}

output "aws_database_name" {
  description = "Name of the database. Null or empty when it is not created."
  value       = module.aws.database_name
}

output "aws_database_credentials_secret_id" {
  description = "ID of the secret that holds the generated database credentials. Null or empty when it is not created."
  value       = module.aws.database_credentials_secret_id
}

output "aws_storage_bucket_name" {
  description = "Name of the object storage bucket. Null or empty when it is not created."
  value       = module.aws.storage_bucket_name
}

output "aws_data_lake_bucket_names" {
  description = "Names of the data-lake buckets. Null or empty when it is not created."
  value       = module.aws.data_lake_bucket_names
}

output "aws_cdn_domain_name" {
  description = "Domain name of the CDN. Null or empty when it is not created."
  value       = module.aws.cdn_domain_name
}

output "aws_waf_id" {
  description = "ID of the web application firewall policy. Null or empty when it is not created."
  value       = module.aws.waf_id
}

output "aws_kms_key_id" {
  description = "ID of the customer-managed key. Null or empty when it is not created."
  value       = module.aws.kms_key_id
}

output "aws_secrets_store_id" {
  description = "ID of the secret store. Null or empty when it is not created."
  value       = module.aws.secrets_store_id
}

output "aws_container_registry_url" {
  description = "URL of the container registry. Null or empty when it is not created."
  value       = module.aws.container_registry_url
}

output "aws_private_dns_zone_name" {
  description = "Name of the private DNS zone. Null or empty when it is not created."
  value       = module.aws.private_dns_zone_name
}

output "aws_backup_vault_id" {
  description = "ID of the backup vault. Null or empty when it is not created."
  value       = module.aws.backup_vault_id
}

output "aws_log_destination_id" {
  description = "ID of the central log destination. Null or empty when it is not created."
  value       = module.aws.log_destination_id
}

output "aws_alert_target_id" {
  description = "ID of the notification target for alerts. Null or empty when it is not created."
  value       = module.aws.alert_target_id
}

output "aws_prometheus_endpoint" {
  description = "Endpoint of the managed Prometheus. Null or empty when it is not created."
  value       = module.aws.prometheus_endpoint
}

output "aws_grafana_endpoint" {
  description = "Endpoint of the managed Grafana. Null or empty when it is not created."
  value       = module.aws.grafana_endpoint
}

output "aws_database_password" {
  description = "Generated database password. Null when the credentials are kept in the secret store or the service has none."
  value       = module.aws.database_password
  sensitive   = true
}

output "aws_kubernetes_cluster_endpoint" {
  description = "Endpoint of the Kubernetes API. Null when the cluster is not created."
  value       = module.aws.kubernetes_cluster_endpoint
  sensitive   = true
}
