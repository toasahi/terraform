output "fqdn" {
  description = "FQDN of the record."
  value       = aws_route53_record.this["A"].fqdn
}

output "health_check_id" {
  description = "Route 53 health check ID (null when none)."
  value       = local.health_check_id
}
