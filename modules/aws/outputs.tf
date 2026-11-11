# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

output "network_id" {
  description = "ID of the VPC in use: the created one or the existing one. Null without a network."
  value       = local.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = local.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = local.private_subnet_ids
}

output "web_security_group_id" {
  description = "Security group for internet-facing load balancers. Null without tiered security groups."
  value       = one(aws_security_group.web[*].id)
}

output "app_security_group_id" {
  description = "Security group for workloads behind the web tier. Null without tiered security groups."
  value       = one(aws_security_group.app[*].id)
}

output "data_security_group_id" {
  description = "Security group of the database. Null without a database inside the VPC."
  value       = one(aws_security_group.data[*].id)
}

output "private_dns_zone_name" {
  description = "Name of the Route 53 private hosted zone. Null unless infrastructure_type is networking-foundation."
  value       = one(aws_route53_zone.private[*].name)
}

# -----------------------------------------------------------------------------
# Kubernetes
# -----------------------------------------------------------------------------

output "kubernetes_cluster_name" {
  description = "Name of the EKS cluster. Null without Kubernetes."
  value       = one(aws_eks_cluster.this[*].name)
}

output "kubernetes_cluster_endpoint" {
  description = "URL of the Kubernetes API server. Null without Kubernetes."
  value       = one(aws_eks_cluster.this[*].endpoint)
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role associated with the service account kube-system/cluster-autoscaler. Null without Kubernetes autoscaling."
  value       = one(aws_iam_role.cluster_autoscaler[*].arn)
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------

output "database_endpoint" {
  description = "Host name of the database, or the regional DynamoDB endpoint. Null without a database."
  value = (
    local.create_rds ? aws_db_instance.this[0].address :
    local.create_docdb ? aws_docdb_cluster.this[0].endpoint :
    local.create_redis ? aws_elasticache_replication_group.this[0].primary_endpoint_address :
    local.create_dynamodb ? "dynamodb.${var.region}.${local.dns_suffix}" :
    null
  )
}

output "database_port" {
  description = "Port of the database. Null for DynamoDB and without a database."
  value       = local.database_port
}

output "database_name" {
  description = "Name of the initial database (RDS) or of the table (DynamoDB). Null for the other engines."
  value = (
    local.create_rds ? aws_db_instance.this[0].db_name :
    local.create_dynamodb ? aws_dynamodb_table.this[0].name :
    null
  )
}

output "database_credentials_secret_id" {
  description = "ARN of the Secrets Manager secret holding the generated database credentials. Null without Secrets Manager or for DynamoDB."
  value = (
    local.create_rds && local.database_password_managed ? aws_db_instance.this[0].master_user_secret[0].secret_arn :
    local.create_docdb && local.database_password_managed ? aws_docdb_cluster.this[0].master_user_secret[0].secret_arn :
    one(aws_secretsmanager_secret.database[*].arn)
  )
}

output "database_password" {
  description = "Generated master password (RDS, DocumentDB) or auth token (Redis). Null when it is kept in Secrets Manager and for DynamoDB."
  value       = var.enable_secrets_manager ? null : one(random_password.database[*].result)
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Storage and delivery
# -----------------------------------------------------------------------------

output "storage_bucket_name" {
  description = "Name of the storage bucket. Null without storage."
  value       = var.enable_storage ? aws_s3_bucket.this["storage"].bucket : null
}

output "data_lake_bucket_names" {
  description = "Names of the raw and curated data-lake buckets. Empty unless infrastructure_type is data-platform or ml-platform."
  value       = [for role in ["raw", "curated"] : aws_s3_bucket.this[role].bucket if local.create_data_lake]
}

output "cdn_domain_name" {
  description = "Domain name of the CloudFront distribution. Null without a CDN."
  value       = one(aws_cloudfront_distribution.this[*].domain_name)
}

output "waf_id" {
  description = "ARN of the WAF web ACL: CloudFront-scoped when there is a CDN, otherwise regional and ready to associate with a load balancer or API. Null without a WAF."
  value       = one(aws_wafv2_web_acl.this[*].arn)
}

output "container_registry_url" {
  description = "URL of the ECR repository. Null unless infrastructure_type is container-platform, ml-platform or serverless-platform."
  value       = one(aws_ecr_repository.this[*].repository_url)
}

# -----------------------------------------------------------------------------
# Security and resilience
# -----------------------------------------------------------------------------

output "kms_key_id" {
  description = "ARN of the customer-managed KMS key. Null without KMS."
  value       = local.kms_key_arn
}

output "secrets_store_id" {
  description = "ARN of the Secrets Manager secret for application configuration. Null without Secrets Manager."
  value       = one(aws_secretsmanager_secret.application[*].arn)
}

output "backup_vault_id" {
  description = "ARN of the AWS Backup vault. Null without a backup plan."
  value       = one(aws_backup_vault.this[*].arn)
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------

output "log_destination_id" {
  description = "ARN of the central CloudWatch log group. Null without monitoring."
  value       = one(aws_cloudwatch_log_group.central[*].arn)
}

output "alert_target_id" {
  description = "ARN of the SNS topic the alarms publish to. Null without alerting."
  value       = one(aws_sns_topic.alerts[*].arn)
}

output "prometheus_endpoint" {
  description = "Endpoint of the managed Prometheus workspace; append api/v1/remote_write to write to it. Null without managed Prometheus."
  value       = one(aws_prometheus_workspace.this[*].prometheus_endpoint)
}

output "grafana_endpoint" {
  description = "URL of the managed Grafana workspace. Null without managed Grafana."
  value       = local.create_grafana ? "https://${aws_grafana_workspace.this[0].endpoint}" : null
}
