# Phase 1 (Tokyo MVP). Flip enable_phase2 for Phase 2; see osaka.tfvars and
# docs/runbooks/phase3-osaka.md for Phase 3.

name        = "alertpipe"
region      = "ap-northeast-1"
role        = "primary"
environment = "prod"

vpc_cidr                   = "10.60.0.0/16"
enable_interface_endpoints = false

public_zone_name    = "example.com."
ingress_domain_name = "alerts.example.com"

alert_sources = ["alertmanager", "cloudwatch", "canary"]

# SaaS sources with published egress ranges go here, keyed by their {source} name.
source_ip_allowlists = {}

api_throttling_rate_limit  = 50
api_throttling_burst_limit = 200

critical_severities = ["critical", "page", "p1", "sev1"]
severity_label      = "severity"
service_label       = "service"

# Service -> room. "default" is mandatory.
routing_entries = {
  default = { room = "ops-alerts" }
  payments = {
    room     = "payments-oncall"
    mentions = ["@payments-oncall"]
  }
  alertpipe-canary = { room = "alertpipe-canary" }
}

comm_tool_webhook_url = "https://comm.internal.example.com/api/v1/webhooks/alerts"

# Keep: mirror first (KEEP_VERSION=<tag> scripts/mirror-keep-images.sh ap-northeast-1 alertpipe)
keep_image_tag         = "REPLACE-ME"
keep_api_desired_count = 2
keep_ui_desired_count  = 1
keep_db_instance_class = "db.t4g.medium"
keep_db_multi_az       = true
keep_create_redis      = true
keep_redis_node_type   = "cache.t4g.small"
keep_extra_environment = {
  # Raise if non-critical delivery may lag Keep restarts by more than an hour.
  ARQ_EXPIRES = "3600"
}

# ---- Phase 2 ----
enable_phase2              = false
enable_canary              = true
escalation_emails          = []
escalation_sms_numbers     = []
escalation_https_endpoints = []

# ---- Phase 3 (fill after the Osaka stack exists) ----
dns_failover_role       = null
dns_health_check        = { type = "https" }
journal_replicas        = {}
secret_replica_regions  = []
ecr_replication_regions = []
