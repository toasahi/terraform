variable "name_prefix" {
  description = "Prefix for queue names. Must not contain the region (same logical names in Tokyo and Osaka)."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for SSE-KMS on every queue."
  type        = string
}

variable "message_retention_seconds" {
  description = "Retention for all main queues. 14 days keeps a backlog through a long Keep or tool outage."
  type        = number
  default     = 1209600
}

variable "dlq_retention_seconds" {
  description = "Retention for dead-letter queues."
  type        = number
  default     = 1209600
}

variable "ingress_visibility_timeout_seconds" {
  description = "Visibility timeout of ingress.standard. Must be >= 6x the Normalize Lambda timeout."
  type        = number
  default     = 180
}

variable "fifo_visibility_timeout_seconds" {
  description = "Visibility timeout of alerts.fifo and keep-delivery.fifo. Must be >= 6x the consuming Lambda timeout."
  type        = number
  default     = 180
}

variable "max_receive_count" {
  description = "Receives before a message is moved to the DLQ."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to all queues."
  type        = map(string)
  default     = {}
}
