variable "create" {
  description = "Create the tables (primary region). When false the tables are expected to exist as global-table replicas and are looked up by name (secondary region)."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for table names. Must not contain the region."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for SSE on the tables in this region."
  type        = string
}

variable "replicas" {
  description = "Global-table replicas keyed by region, e.g. { \"ap-northeast-3\" = { kms_key_arn = \"arn:...\" } }. Empty until Phase 3. Only used when create = true."
  type = map(object({
    kms_key_arn = string
  }))
  default = {}
}

variable "routing_entries" {
  description = "Service -> room mapping seeded into the routing table. Key is the service name; use the key \"default\" as the fallback room."
  type = map(object({
    room     = string
    mentions = optional(list(string), [])
  }))
  default = {}
}

variable "tags" {
  description = "Tags applied to all tables."
  type        = map(string)
  default     = {}
}
