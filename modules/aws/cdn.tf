locals {
  cdn_custom_certificate = var.cdn_acm_certificate_arn != null

  log_cdn = local.create_cdn && var.enable_monitoring

  # A web ACL for CloudFront lives in the global region together with its
  # logs; a regional one lives next to the load balancers it protects.
  waf_name        = var.name_prefix
  waf_scope       = local.create_cdn ? "CLOUDFRONT" : "REGIONAL"
  waf_region      = local.create_cdn ? local.global_region : var.region
  waf_kms_key_arn = local.create_cdn ? local.global_kms_key_arn : local.kms_key_arn
  log_waf         = var.enable_waf && var.enable_monitoring

  # AWS managed rule groups, evaluated in this order after the rate limit.
  waf_managed_rule_groups = [
    "AWSManagedRulesAmazonIpReputationList",
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesSQLiRuleSet",
  ]

  # Requests one client address may send in five minutes.
  waf_rate_limit = 2000
}

# -----------------------------------------------------------------------------
# CloudFront in front of the storage bucket
# -----------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = local.create_cdn ? 1 : 0

  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  count = local.create_cdn ? 1 : 0

  name = "Managed-SecurityHeadersPolicy"
}

# Signs the requests CloudFront sends to the bucket, which admits nothing else.
resource "aws_cloudfront_origin_access_control" "this" {
  count = local.create_cdn ? 1 : 0

  name                              = "${var.name_prefix}-storage"
  description                       = "CloudFront access to the ${var.name_prefix} storage bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  count = local.create_cdn ? 1 : 0

  comment             = "CDN of ${var.name_prefix}"
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  default_root_object = "index.html"
  price_class         = local.cost_optimized ? "PriceClass_100" : "PriceClass_All"
  aliases             = var.cdn_aliases
  web_acl_id          = one(aws_wafv2_web_acl.this[*].arn)

  origin {
    origin_id                = "storage"
    domain_name              = aws_s3_bucket.this["storage"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.this[0].id
  }

  default_cache_behavior {
    target_origin_id           = "storage"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized[0].id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # A custom domain negotiates TLS 1.2 or newer. The cloudfront.net default
  # certificate has a protocol policy fixed by CloudFront.
  viewer_certificate {
    cloudfront_default_certificate = !local.cdn_custom_certificate
    acm_certificate_arn            = var.cdn_acm_certificate_arn
    ssl_support_method             = local.cdn_custom_certificate ? "sni-only" : null
    minimum_protocol_version       = local.cdn_custom_certificate ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = var.tags
}

# CloudFront delivers its access logs through CloudWatch Logs in the global
# region.
resource "aws_cloudwatch_log_group" "cdn" {
  count = local.log_cdn ? 1 : 0

  region            = local.global_region
  name              = "/aws/vendedlogs/cloudfront/${var.name_prefix}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.global_kms_key_arn

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery_source" "cdn" {
  count = local.log_cdn ? 1 : 0

  region       = local.global_region
  name         = "${var.name_prefix}-cdn"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.this[0].arn

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery_destination" "cdn" {
  count = local.log_cdn ? 1 : 0

  region        = local.global_region
  name          = "${var.name_prefix}-cdn"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.cdn[0].arn
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_delivery" "cdn" {
  count = local.log_cdn ? 1 : 0

  region                   = local.global_region
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cdn[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cdn[0].arn

  tags = var.tags
}

# -----------------------------------------------------------------------------
# WAF: attached to the CDN when there is one, otherwise regional and ready to
# associate with the user's load balancer or API
# -----------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  region      = local.waf_region
  name        = local.waf_name
  description = "Managed rules protecting ${var.name_prefix}"
  scope       = local.waf_scope

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = local.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups

    content {
      name     = rule.value
      priority = rule.key + 1

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.waf_name
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# WAF only logs to groups whose name starts with aws-waf-logs-, in the region
# of the web ACL.
resource "aws_cloudwatch_log_group" "waf" {
  count = local.log_waf ? 1 : 0

  region            = local.waf_region
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = local.log_retention_days
  kms_key_id        = local.waf_kms_key_arn

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = local.log_waf ? 1 : 0

  region                  = local.waf_region
  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
}
