variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (the function runs in the VPC to reach the internal ALB)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group of the Keep ALB to open."
  type        = string
}

variable "keep_api_url" {
  description = "Internal Keep API URL."
  type        = string
}

variable "keep_api_port" {
  description = "Keep API listener port."
  type        = number
}

variable "keep_app_secret_arn" {
  description = "Secret holding the Keep API key (json key api_key)."
  type        = string
}

variable "keep_delivery_queue_arn" {
  description = "keep-delivery.fifo ARN (event source)."
  type        = string
}

variable "journal_table_arn" {
  description = "Journal table ARN."
  type        = string
}

variable "journal_table_name" {
  description = "Journal table name."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key."
  type        = string
}

variable "source_dir" {
  description = "Directory of the dispatcher code."
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
