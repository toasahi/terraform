# ---- Identity ---------------------------------------------------------------------

variable "name" {
  description = "Logical name of the stack. Used as prefix for every resource and MUST NOT contain the region (same logical names in Tokyo and Osaka)."
  type        = string
  default     = "alertpipe"
}

variable "region" {
  description = "AWS region this stack is applied to."
  type        = string
}

variable "role" {
  description = "\"primary\" (Tokyo: owns the global tables, Multi-AZ DB, running Keep) or \"secondary\" (Osaka: pilot light)."
  type        = string
  default     = "primary"

  validation {
    condition     = contains(["primary", "secondary"], var.role)
    error_message = "role must be primary or secondary."
  }
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "prod"
}

variable "extra_tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---- Network --------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR for the ops account network in this region."
  type        = string
}

variable "enable_interface_endpoints" {
  description = "Create interface VPC endpoints instead of sending AWS API traffic through the Regional NAT Gateway."
  type        = bool
  default     = false
}

# ---- Ingress ----------------------------------------------------------------------------

variable "public_zone_name" {
  description = "Public hosted zone that holds the ingress record (e.g. example.com.)."
  type        = string
}

variable "ingress_domain_name" {
  description = "FQDN monitoring sources post to (e.g. alerts.example.com). Lives in the public hosted zone so SaaS sources and Route 53 health checks can reach it."
  type        = string
}

variable "alert_sources" {
  description = "Source names accepted on POST /v1/alerts/{source}. A random token is generated per source and stored in Secrets Manager. Names starting with alertmanager / cloudwatch select the matching adapter; others use the generic schema. \"canary\" is required when the canary is enabled."
  type        = list(string)
  default     = ["alertmanager", "cloudwatch", "canary"]
}

variable "source_ip_allowlists" {
  description = "Per-source CIDR allow lists enforced by WAF for SaaS that publish their egress IPs."
  type        = map(list(string))
  default     = {}
}

variable "api_throttling_rate_limit" {
  description = "Steady-state requests/second on the ingress stage."
  type        = number
  default     = 50
}

variable "api_throttling_burst_limit" {
  description = "Burst requests on the ingress stage."
  type        = number
  default     = 200
}

variable "manage_api_gateway_account_role" {
  description = "Create the account-level API Gateway CloudWatch role in this region."
  type        = bool
  default     = true
}

variable "dns_failover_role" {
  description = "null (Phase 1/2: simple record), \"PRIMARY\" or \"SECONDARY\" (Phase 3)."
  type        = string
  default     = null
}

variable "dns_health_check" {
  description = "Health check for the failover record. type = https (probe this region's execute-api /healthz) or cloudwatch_alarm (follow the other region's canary alarm)."
  type = object({
    type         = string
    alarm_name   = optional(string)
    alarm_region = optional(string)
  })
  default = { type = "https" }
}

# ---- Normalization -------------------------------------------------------------------------

variable "critical_severities" {
  description = "Severity label values treated as critical (case-insensitive)."
  type        = list(string)
  default     = ["critical", "page", "p1", "sev1"]
}

variable "severity_label" {
  description = "Label that carries the severity in Alertmanager payloads."
  type        = string
  default     = "severity"
}

variable "service_label" {
  description = "Label that carries the service name in Alertmanager payloads."
  type        = string
  default     = "service"
}

# ---- Journal / routing ------------------------------------------------------------------------

variable "journal_replicas" {
  description = "Primary only. Global-table replicas keyed by region with that region's KMS key ARN (Phase 3)."
  type = map(object({
    kms_key_arn = string
  }))
  default = {}
}

variable "routing_entries" {
  description = "Service -> room mapping (Git-managed). Key \"default\" is the fallback."
  type = map(object({
    room     = string
    mentions = optional(list(string), [])
  }))
}

variable "comm_tool_webhook_url" {
  description = "Inbound webhook URL of the in-house communication tool. The auth value is set out-of-band in Secrets Manager (see README)."
  type        = string
}

# ---- Keep ---------------------------------------------------------------------------------------

variable "keep_image_tag" {
  description = "Upstream Keep version mirrored into ECR (scripts/mirror-keep-images.sh)."
  type        = string
}

variable "keep_api_desired_count" {
  description = "keep-api tasks (2 in Tokyo, 0 in Osaka until activation)."
  type        = number
  default     = 2
}

variable "keep_ui_desired_count" {
  description = "keep-ui tasks (1 in Tokyo, 0 in Osaka)."
  type        = number
  default     = 1
}

variable "keep_extra_environment" {
  description = "Extra environment variables for keep-api (e.g. ARQ_EXPIRES)."
  type        = map(string)
  default     = {}
}

variable "keep_db_instance_class" {
  description = "RDS instance class for Keep."
  type        = string
  default     = "db.t4g.medium"
}

variable "keep_db_multi_az" {
  description = "Multi-AZ for the Keep database."
  type        = bool
  default     = true
}

variable "keep_db_replicate_source_arn" {
  description = "Secondary only: ARN of the Tokyo Keep DB instance to replicate."
  type        = string
  default     = null
}

variable "keep_db_password_source_secret_arn" {
  description = "Secondary only: ARN (in this region) of the replicated Tokyo DB secret."
  type        = string
  default     = null
}

variable "keep_app_secret_source_arn" {
  description = "Secondary only: ARN (in this region) of the replicated Keep app secret."
  type        = string
  default     = null
}

variable "keep_create_redis" {
  description = "Create Redis for ARQ (true in Tokyo; false in Osaka until activation)."
  type        = bool
  default     = true
}

variable "keep_redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.small"
}

variable "secret_replica_regions" {
  description = "Primary only. Regions the DB / app secrets are replicated to (Phase 3)."
  type        = list(string)
  default     = []
}

variable "ecr_replication_regions" {
  description = "Primary only. Regions the Keep images are replicated to (Phase 3)."
  type        = list(string)
  default     = []
}

# ---- Phase 2 ---------------------------------------------------------------------------------------

variable "enable_phase2" {
  description = "Create the Reconciler, heartbeats, DLQ alarms and the independent SNS path."
  type        = bool
  default     = false
}

variable "enable_canary" {
  description = "Run the ingress canary from this region (Phase 2: Tokyo; Phase 3: Osaka too)."
  type        = bool
  default     = true
}

variable "escalation_emails" {
  description = "E-mail subscribers of the independent SNS path."
  type        = list(string)
  default     = []
}

variable "escalation_sms_numbers" {
  description = "SMS subscribers of the independent SNS path (E.164)."
  type        = list(string)
  default     = []
}

variable "escalation_https_endpoints" {
  description = "HTTPS subscribers of the independent SNS path."
  type        = list(string)
  default     = []
}

variable "reconciler_keep_pending_minutes" {
  description = "Minutes before a keep_status=pending transition is re-delivered."
  type        = number
  default     = 10
}

variable "reconciler_notify_pending_minutes" {
  description = "Minutes before an undelivered critical alert is escalated on SNS."
  type        = number
  default     = 5
}

# ---- Misc ---------------------------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for every log group."
  type        = number
  default     = 90
}
