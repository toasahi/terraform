output "rest_api_id" {
  description = "REST API ID."
  value       = aws_api_gateway_rest_api.this.id
}

output "stage_name" {
  description = "Stage name."
  value       = aws_api_gateway_stage.this.stage_name
}

output "execution_endpoint" {
  description = "Default execute-api hostname (used by Route 53 HTTPS health checks)."
  value       = "${aws_api_gateway_rest_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com"
}

output "regional_domain_name" {
  description = "Regional domain name of the custom domain (alias target)."
  value       = aws_api_gateway_domain_name.this.regional_domain_name
}

output "regional_zone_id" {
  description = "Hosted zone ID of the regional custom domain (alias target)."
  value       = aws_api_gateway_domain_name.this.regional_zone_id
}

output "alerts_url" {
  description = "Base URL that sources post to (append /<source>)."
  value       = "https://${var.domain_name}/v1/alerts"
}

output "authorizer_function_name" {
  description = "Authorizer Lambda name."
  value       = module.authorizer.function_name
}

output "web_acl_arn" {
  description = "WAF web ACL ARN."
  value       = aws_wafv2_web_acl.this.arn
}
