output "independent_sns_topic_arn" {
  description = "ARN of the independent notification topic."
  value       = aws_sns_topic.independent.arn
}

output "ingress_heartbeat_alarm_names" {
  description = "Names of the ingress heartbeat alarms (Route 53 CLOUDWATCH_METRIC health checks in Phase 3)."
  value       = { for k, a in aws_cloudwatch_metric_alarm.heartbeat : k => a.alarm_name }
}

output "canary_function_name" {
  description = "Canary function name (null when disabled)."
  value       = var.enable_canary ? module.canary[0].function_name : null
}

output "canary_posted_alarm_name" {
  description = "Alarm that is red when this region's canary cannot reach the ingress (null when disabled)."
  value       = var.enable_canary ? aws_cloudwatch_metric_alarm.canary_posted[0].alarm_name : null
}
