output "ingress_alerts_url" {
  description = "Base URL sources post to: <url>/<source> with header X-Alert-Token."
  value       = local.alerts_url
}

output "ingress_execution_endpoint" {
  description = "Default execute-api hostname of this region's ingress (for HTTPS health checks)."
  value       = module.ingress.execution_endpoint
}

output "source_tokens_secret_arn" {
  description = "Secret holding the per-source tokens."
  value       = aws_secretsmanager_secret.source_tokens.arn
}

output "comm_tool_secret_arn" {
  description = "Secret to fill with the communication tool auth value."
  value       = aws_secretsmanager_secret.comm_tool.arn
}

output "queues" {
  description = "Queue URLs."
  value = {
    ingress       = module.queues.ingress.url
    alerts_fifo   = module.queues.alerts_fifo.url
    keep_delivery = module.queues.keep_delivery_fifo.url
  }
}

output "journal_table_name" {
  description = "AlertEventJournal table name."
  value       = module.journal.journal_table_name
}

output "kms_key_arn" {
  description = "Regional KMS key ARN (needed by the other region for global-table replicas)."
  value       = module.kms.key_arn
}

output "keep" {
  description = "Keep endpoints and identifiers."
  value = {
    api_url                = module.keep.keep_api_url
    ui_url                 = module.keep.keep_ui_url
    cluster_name           = module.keep.cluster_name
    api_service_name       = module.keep.api_service_name
    ecr_repository_urls    = module.keep.ecr_repository_urls
    db_instance_arn        = module.keep_datastore.db_instance_arn
    db_instance_identifier = module.keep_datastore.db_instance_identifier
    db_secret_arn          = module.keep_datastore.db_secret_arn
    app_secret_arn         = module.keep.app_secret_arn
  }
}

output "independent_sns_topic_arn" {
  description = "Independent notification topic (Phase 2)."
  value       = var.enable_phase2 ? module.observability[0].independent_sns_topic_arn : null
}

output "canary_posted_alarm_name" {
  description = "Alarm to reference from the other region's failover health check (Phase 3)."
  value       = var.enable_phase2 ? module.observability[0].canary_posted_alarm_name : null
}
