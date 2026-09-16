variable "function_name" {
  description = "Lambda function name."
  type        = string
}

variable "description" {
  description = "Function description."
  type        = string
  default     = ""
}

variable "source_dir" {
  description = "Directory with the handler code."
  type        = string
}

variable "build_dir" {
  description = "Directory where the zip archive is written."
  type        = string
}

variable "handler" {
  description = "Handler entry point."
  type        = string
  default     = "handler.lambda_handler"
}

variable "runtime" {
  description = "Lambda runtime."
  type        = string
  default     = "python3.12"
}

variable "architecture" {
  description = "CPU architecture."
  type        = string
  default     = "arm64"
}

variable "memory_size" {
  description = "Memory in MB."
  type        = number
  default     = 256
}

variable "timeout" {
  description = "Timeout in seconds."
  type        = number
  default     = 30
}

variable "reserved_concurrent_executions" {
  description = "Reserved concurrency (-1 = unreserved)."
  type        = number
  default     = -1
}

variable "environment" {
  description = "Environment variables."
  type        = map(string)
  default     = {}
}

variable "layers" {
  description = "Layer ARNs."
  type        = list(string)
  default     = []
}

variable "policy_json" {
  description = "Inline IAM policy document (JSON) granting the function its least-privilege permissions. Null for none."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "KMS key for environment variable encryption and the log group."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch log retention."
  type        = number
  default     = 90
}

variable "vpc_config" {
  description = "Attach the function to a VPC. Null keeps it outside (preferred for the critical path)."
  type = object({
    subnet_ids         = list(string)
    security_group_ids = list(string)
  })
  default = null
}

variable "sqs_event_source" {
  description = "Attach an SQS event source mapping. Batch partial failures are always reported."
  type = object({
    queue_arn                          = string
    batch_size                         = optional(number, 10)
    maximum_batching_window_in_seconds = optional(number, 0)
    maximum_concurrency                = optional(number, null)
  })
  default = null
}

variable "dead_letter_queue_arn" {
  description = "SQS ARN used as on-failure destination for asynchronous invocations (schedule-triggered functions)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
