# Phase 3 (Osaka pilot light). Apply ONLY after Tokyo has been re-applied with
# journal_replicas / secret_replica_regions / ecr_replication_regions set.
# The three REPLACE-ME ARNs come from the Tokyo outputs (keep.db_instance_arn,
# keep.db_secret_arn, keep.app_secret_arn: use the replica ARNs in ap-northeast-3).

name        = "alertpipe"
region      = "ap-northeast-3"
role        = "secondary"
environment = "prod"

vpc_cidr                   = "10.61.0.0/16"
enable_interface_endpoints = false

public_zone_name    = "example.com."
ingress_domain_name = "alerts.example.com"

alert_sources        = ["alertmanager", "cloudwatch", "canary"]
source_ip_allowlists = {}

critical_severities = ["critical", "page", "p1", "sev1"]

routing_entries = {
  default          = { room = "ops-alerts" }
  alertpipe-canary = { room = "alertpipe-canary" }
}

comm_tool_webhook_url = "https://comm.internal.example.com/api/v1/webhooks/alerts"

keep_image_tag                     = "REPLACE-ME"
keep_api_desired_count             = 0 # pilot light: start on failover
keep_ui_desired_count              = 0
keep_db_instance_class             = "db.t4g.medium"
keep_db_multi_az                   = false # P1: raise to true
keep_db_replicate_source_arn       = "REPLACE-ME-arn:aws:rds:ap-northeast-1:ACCOUNT:db:alertpipe-keep"
keep_db_password_source_secret_arn = "REPLACE-ME-arn:aws:secretsmanager:ap-northeast-3:ACCOUNT:secret:alertpipe/keep/database"
keep_app_secret_source_arn         = "REPLACE-ME-arn:aws:secretsmanager:ap-northeast-3:ACCOUNT:secret:alertpipe/keep/app"
keep_create_redis                  = false # Keep falls back to in-process workers until Redis is added

enable_phase2 = true
enable_canary = true # the Osaka canary is the external monitor of the Tokyo ingress

dns_failover_role = "SECONDARY"
dns_health_check  = { type = "https" }
