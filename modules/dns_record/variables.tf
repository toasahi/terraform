variable "zone_id" {
  description = "Public hosted zone ID."
  type        = string
}

variable "name" {
  description = "Record name (FQDN) that monitoring sources call."
  type        = string
}

variable "alias_name" {
  description = "Regional domain name of the API Gateway custom domain."
  type        = string
}

variable "alias_zone_id" {
  description = "Hosted zone ID of the API Gateway regional domain."
  type        = string
}

variable "failover_role" {
  description = "null for a simple record (Phase 1), \"PRIMARY\" or \"SECONDARY\" for Route 53 failover (Phase 3)."
  type        = string
  default     = null

  validation {
    condition     = var.failover_role == null || contains(["PRIMARY", "SECONDARY"], coalesce(var.failover_role, "PRIMARY"))
    error_message = "failover_role must be null, PRIMARY or SECONDARY."
  }
}

variable "set_identifier" {
  description = "Set identifier for failover records (typically the region)."
  type        = string
  default     = null
}

variable "health_check" {
  description = "Health check attached to a failover record. type = \"https\" probes fqdn + resource_path from Route 53 checkers; type = \"cloudwatch_alarm\" follows a CloudWatch alarm (canary from the other region)."
  type = object({
    type          = string
    fqdn          = optional(string)
    resource_path = optional(string, "/healthz")
    alarm_name    = optional(string)
    alarm_region  = optional(string)
  })
  default = null
}

variable "tags" {
  description = "Tags applied to the health check."
  type        = map(string)
  default     = {}
}
