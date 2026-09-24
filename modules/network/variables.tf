variable "name" {
  description = "Name prefix for network resources."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR block."
  type        = string
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets over (Keep runs in 2 AZs)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 so that Keep, RDS and Redis are Multi-AZ."
  }
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints (SQS, Secrets Manager, KMS, Logs, ECR, Monitoring). Off by default: the Regional NAT Gateway carries this traffic and the volume is small. Gateway endpoints for S3/DynamoDB are always created (free)."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention of VPC flow logs in CloudWatch Logs."
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt the flow log group."
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
