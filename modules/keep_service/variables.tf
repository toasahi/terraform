variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR (operators inside the VPC may reach the UI/API listeners)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the ALB and tasks (2 AZs)."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for secrets and log groups."
  type        = string
}

variable "keep_image_tag" {
  description = "Tag of the keep-api / keep-ui images mirrored into ECR (pinned, e.g. \"0.50.0\")."
  type        = string
}

variable "api_desired_count" {
  description = "Number of Keep API tasks. 2 in Tokyo, 0 in Osaka until activation."
  type        = number
  default     = 2
}

variable "ui_desired_count" {
  description = "Number of Keep UI tasks (0 to disable the UI)."
  type        = number
  default     = 1
}

variable "api_cpu" {
  description = "Fargate CPU units for the API task."
  type        = number
  default     = 1024
}

variable "api_memory" {
  description = "Fargate memory (MiB) for the API task."
  type        = number
  default     = 2048
}

variable "ui_cpu" {
  description = "Fargate CPU units for the UI task."
  type        = number
  default     = 512
}

variable "ui_memory" {
  description = "Fargate memory (MiB) for the UI task."
  type        = number
  default     = 1024
}

variable "db_secret_arn" {
  description = "Secrets Manager secret with the connection_string JSON key."
  type        = string
}

variable "db_security_group_id" {
  description = "Security group of PostgreSQL to open for the tasks."
  type        = string
}

variable "redis" {
  description = "Redis endpoint; null disables ARQ (Keep falls back to in-process workers)."
  type = object({
    host              = string
    port              = number
    security_group_id = string
  })
  default = null
}

variable "alerts_fifo" {
  description = "alerts.fifo queue the Keep workflow writes to."
  type = object({
    arn = string
    url = string
  })
}

variable "keep_extra_environment" {
  description = "Additional environment variables for the Keep API container (e.g. ARQ_EXPIRES)."
  type        = map(string)
  default     = {}
}

variable "ecr_replication_regions" {
  description = "Regions the ECR images are replicated to (registry-level, primary only, Phase 3)."
  type        = list(string)
  default     = []
}

variable "secret_replica_regions" {
  description = "Regions the Keep application secret is replicated to (Phase 3)."
  type        = list(string)
  default     = []
}

variable "app_secret_source_arn" {
  description = "Secondary region only: ARN of the replicated application secret to reuse instead of generating new credentials."
  type        = string
  default     = null
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
