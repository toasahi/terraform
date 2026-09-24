# Public record that every monitoring source (including in-cluster Alertmanager)
# uses. Phase 1 creates a plain alias; Phase 3 flips the same record to a
# failover PRIMARY (Tokyo) / SECONDARY (Osaka) pair by setting failover_role.
# Sources never change their configuration.

resource "aws_route53_health_check" "https" {
  count = var.health_check != null && try(var.health_check.type, "") == "https" ? 1 : 0

  fqdn              = var.health_check.fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check.resource_path
  failure_threshold = 3
  request_interval  = 10
  enable_sni        = true
  measure_latency   = true

  tags = merge(var.tags, { Name = "${var.name}-${coalesce(var.set_identifier, "simple")}" })
}

resource "aws_route53_health_check" "alarm" {
  count = var.health_check != null && try(var.health_check.type, "") == "cloudwatch_alarm" ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = var.health_check.alarm_name
  cloudwatch_alarm_region         = var.health_check.alarm_region
  insufficient_data_health_status = "Unhealthy"

  tags = merge(var.tags, { Name = "${var.name}-${coalesce(var.set_identifier, "simple")}" })
}

locals {
  health_check_id = try(aws_route53_health_check.https[0].id, aws_route53_health_check.alarm[0].id, null)
}

resource "aws_route53_record" "this" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.zone_id
  name    = var.name
  type    = each.key

  alias {
    name                   = var.alias_name
    zone_id                = var.alias_zone_id
    evaluate_target_health = false
  }

  set_identifier  = var.failover_role == null ? null : var.set_identifier
  health_check_id = var.failover_role == null ? null : local.health_check_id

  dynamic "failover_routing_policy" {
    for_each = var.failover_role == null ? [] : [var.failover_role]
    content {
      type = failover_routing_policy.value
    }
  }
}
