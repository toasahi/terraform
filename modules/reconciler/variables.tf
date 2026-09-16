variable "name" {
  description = "Name prefix."
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge schedule for the reconciler."
  type        = string
  default     = "rate(5 minutes)"
}

variable "journal" {
  description = "Journal table (name, arn)."
  type = object({
    name = string
    arn  = string
  })
}

variable "keep_delivery_fifo" {
  description = "keep-delivery.fifo (arn, url)."
  type = object({
    arn = string
    url = string
  })
}

variable "independent_sns_topic_arn" {
  description = "SNS topic of the independent notification path."
  type        = string
}

variable "keep_pending_minutes" {
  description = "Minutes a transition may stay keep_status=pending before re-delivery."
  type        = number
  default     = 10
}

variable "notify_pending_minutes" {
  description = "Minutes a critical transition may stay notification_status=pending before SNS escalation."
  type        = number
  default     = 5
}

variable "kms_key_arn" {
  description = "KMS key."
  type        = string
}

variable "source_dir" {
  description = "Directory of the reconciler code."
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
