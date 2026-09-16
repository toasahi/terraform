output "keep_api_url" {
  description = "Internal URL of the Keep API (used by the Dispatcher and the UI)."
  value       = local.keep_api_url
}

output "keep_ui_url" {
  description = "Internal URL of the Keep UI."
  value       = local.keep_ui_url
}

output "alb_security_group_id" {
  description = "Security group of the internal ALB (the Dispatcher adds an ingress rule)."
  value       = aws_security_group.alb.id
}

output "api_port" {
  description = "Port of the API listener."
  value       = local.api_port
}

output "app_secret_arn" {
  description = "Secrets Manager secret with Keep credentials (api_key key is read by the Dispatcher)."
  value       = local.app_secret_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URLs keyed by api / ui."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "api_service_name" {
  description = "ECS service name of keep-api."
  value       = aws_ecs_service.api.name
}

output "task_security_group_id" {
  description = "Security group of the Keep tasks."
  value       = aws_security_group.tasks.id
}

output "alb_arn_suffix" {
  description = "ARN suffix of the internal ALB (CloudWatch dimension)."
  value       = aws_lb.this.arn_suffix
}

output "api_target_group_arn_suffix" {
  description = "ARN suffix of the keep-api target group (CloudWatch dimension)."
  value       = aws_lb_target_group.api.arn_suffix
}
