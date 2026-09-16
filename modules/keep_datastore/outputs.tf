output "db_security_group_id" {
  description = "Security group of the PostgreSQL instance (keep_service adds ingress rules)."
  value       = aws_security_group.db.id
}

output "db_endpoint" {
  description = "PostgreSQL endpoint hostname."
  value       = local.db_endpoint
}

output "db_instance_arn" {
  description = "ARN of the PostgreSQL instance (source for cross-region replicas)."
  value       = local.db_arn
}

output "db_instance_identifier" {
  description = "Identifier of the PostgreSQL instance."
  value       = local.db_id
}

output "db_secret_arn" {
  description = "Secrets Manager secret ARN with the connection string."
  value       = aws_secretsmanager_secret.db.arn
}

output "redis_security_group_id" {
  description = "Security group of Redis (null when not created)."
  value       = var.create_redis ? aws_security_group.redis[0].id : null
}

output "redis_endpoint" {
  description = "Redis primary endpoint (null when not created)."
  value       = var.create_redis ? aws_elasticache_replication_group.this[0].primary_endpoint_address : null
}

output "redis_port" {
  description = "Redis port."
  value       = 6379
}
