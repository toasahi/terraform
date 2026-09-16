variable "name" {
  description = "Name prefix."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for the SNS topic and log groups."
  type        = string
}

variable "escalation_emails" {
  description = "E-mail subscriptions on the independent SNS path."
  type        = list(string)
  default     = []
}

variable "escalation_sms_numbers" {
  description = "SMS (E.164) subscriptions on the independent SNS path."
  type        = list(string)
  default     = []
}

variable "escalation_https_endpoints" {
  description = "HTTPS webhook subscriptions on the independent SNS path (e.g. the on-call tool's inbound webhook)."
  type        = list(string)
  default     = []
}

variable "dlqs" {
  description = "DLQ names to alarm on when any message lands."
  type        = map(string)
}

variable "queues" {
  description = "Main queue names and the max age (seconds) of the oldest message before alarming."
  type = map(object({
    name        = string
    max_age_sec = number
  }))
}

variable "lambda_function_names" {
  description = "Lambda functions to alarm on errors."
  type        = map(string)
}

variable "rest_api_name" {
  description = "API Gateway REST API name (5xx alarm)."
  type        = string
}

variable "rest_api_stage" {
  description = "API Gateway stage name."
  type        = string
}

variable "keep_alb_arn_suffix" {
  description = "ALB ARN suffix of the Keep load balancer (unhealthy host alarm)."
  type        = string
}

variable "keep_api_target_group_arn_suffix" {
  description = "Target group ARN suffix of keep-api."
  type        = string
}

variable "metrics_namespace" {
  description = "EMF namespace used by the Lambdas."
  type        = string
  default     = "AlertPipe"
}

variable "enable_canary" {
  description = "Run the ingress synthetic heartbeat from this region."
  type        = bool
  default     = true
}

variable "canary_schedule_expression" {
  description = "How often the canary posts (Phase 2: every minute)."
  type        = string
  default     = "rate(1 minute)"
}

variable "canary_target_alerts_url" {
  description = "Public ingress base URL the canary posts to (https://<domain>/v1/alerts)."
  type        = string
}

variable "canary_target_region" {
  description = "Region label of the ingress under test (for DR the Osaka canary tests Tokyo)."
  type        = string
}

variable "source_tokens_secret_arn" {
  description = "Secret with per-source tokens (the canary uses key \"canary\")."
  type        = string
}

variable "heartbeat_missing_periods" {
  description = "Consecutive 1-minute periods without a heartbeat before alarming."
  type        = number
  default     = 5
}

variable "source_dir" {
  description = "Directory of the canary code."
  type        = string
}

variable "build_dir" {
  description = "Directory where Lambda zips are written."
  type        = string
}

variable "layer_arns" {
  description = "Shared layer ARNs."
  type        = list(string)
}

variable "async_dlq_arn" {
  description = "SQS ARN for failed asynchronous invocations."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
