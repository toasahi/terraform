variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "data_subnet_ids" {
  description = "Isolated data subnets for RDS and ElastiCache."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "KMS key for storage encryption and the connection secret."
  type        = string
}

variable "db_role" {
  description = "\"primary\" creates a Multi-AZ PostgreSQL instance; \"replica\" creates a cross-region read replica of db_replicate_source_arn (Phase 3, Osaka)."
  type        = string
  default     = "primary"

  validation {
    condition     = contains(["primary", "replica"], var.db_role)
    error_message = "db_role must be primary or replica."
  }
}

variable "db_replicate_source_arn" {
  description = "ARN of the source instance when db_role = replica."
  type        = string
  default     = null
}

variable "db_password_source_secret_arn" {
  description = "When db_role = replica: ARN of the primary's connection secret replicated into this region (Secrets Manager multi-region replication). The password is read from it so the local connection secret can be built."
  type        = string
  default     = null
}

variable "db_engine_version" {
  description = "PostgreSQL major or full version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial storage in GiB (gp3)."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Multi-AZ deployment. True for Tokyo. The Osaka replica starts single-AZ (P1 to raise)."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Automated backup retention. Must be > 0 on the primary so cross-region replicas can be created later."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Deletion protection on the instance."
  type        = bool
  default     = true
}

variable "secret_replica_regions" {
  description = "Regions the DB connection secret is replicated to (Phase 3)."
  type        = list(string)
  default     = []
}

variable "create_redis" {
  description = "Create the Redis (ARQ) replication group. False in the DR region until activation."
  type        = bool
  default     = true
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

variable "redis_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
