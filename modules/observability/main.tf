# Phase 2: the independent notification path and the alarms that feed it.
# Everything here alarms INTO SNS, which reaches humans without the routing
# tool, Keep or the communication tool being alive.

data "aws_region" "current" {}

# ---- Independent SNS path --------------------------------------------------------------

resource "aws_sns_topic" "independent" {
  name              = "${var.name}-independent-notify"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.escalation_emails)

  topic_arn = aws_sns_topic.independent.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "sms" {
  for_each = toset(var.escalation_sms_numbers)

  topic_arn = aws_sns_topic.independent.arn
  protocol  = "sms"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "https" {
  for_each = toset(var.escalation_https_endpoints)

  topic_arn = aws_sns_topic.independent.arn
  protocol  = "https"
  endpoint  = each.value
}

locals {
  alarm_actions = [aws_sns_topic.independent.arn]
}

# ---- Queue alarms ------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = var.dlqs

  alarm_name          = "${var.name}-dlq-${each.key}"
  alarm_description   = "Messages in ${each.value}: a consumer is failing or poison messages arrived"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = var.queues

  alarm_name          = "${var.name}-oldest-message-${each.key}"
  alarm_description   = "Oldest message in ${each.value.name} older than ${each.value.max_age_sec}s: the consumer is down or stuck"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = each.value.max_age_sec
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

# ---- Lambda / API / ALB alarms -------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_function_names

  alarm_name          = "${var.name}-lambda-errors-${each.key}"
  alarm_description   = "Errors in ${each.value}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name}-ingress-5xx"
  alarm_description   = "Ingress API returning 5xx (SQS integration or authorizer failure)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = var.rest_api_name, Stage = var.rest_api_stage }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "keep_unhealthy" {
  alarm_name          = "${var.name}-keep-api-unhealthy"
  alarm_description   = "No healthy keep-api target behind the ALB (non-critical alerts queue up in keep-delivery.fifo)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = var.keep_alb_arn_suffix, TargetGroup = var.keep_api_target_group_arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

# ---- Heartbeats (EMF metrics emitted by the routing tool) ---------------------------------

locals {
  heartbeats = {
    ingress-direct = { metric = "IngressHeartbeat", dimensions = { Region = data.aws_region.current.region, path = "direct" } }
    ingress-keep   = { metric = "IngressHeartbeat", dimensions = { Region = data.aws_region.current.region, path = "keep" } }
    keep-scheduler = { metric = "KeepProcessingHeartbeat", dimensions = { Region = data.aws_region.current.region } }
  }
}

resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  for_each = local.heartbeats

  alarm_name          = "${var.name}-heartbeat-${each.key}"
  alarm_description   = "Heartbeat ${each.key} missing for ${var.heartbeat_missing_periods} minutes (silent failure somewhere between entry and exit)"
  namespace           = var.metrics_namespace
  metric_name         = each.value.metric
  dimensions          = each.value.dimensions
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = var.heartbeat_missing_periods
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}

# ---- Ingress canary -------------------------------------------------------------------------

data "aws_iam_policy_document" "canary" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.source_tokens_secret_arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

module "canary" {
  count  = var.enable_canary ? 1 : 0
  source = "../lambda_function"

  function_name = "${var.name}-ingress-canary"
  description   = "Posts a heartbeat alert through the public ingress"
  source_dir    = var.source_dir
  build_dir     = var.build_dir
  layers        = var.layer_arns
  memory_size   = 128
  timeout       = 20
  kms_key_arn   = var.kms_key_arn
  policy_json   = data.aws_iam_policy_document.canary.json

  reserved_concurrent_executions = 1
  dead_letter_queue_arn          = var.async_dlq_arn

  environment = {
    INGRESS_ALERTS_URL       = var.canary_target_alerts_url
    SOURCE_TOKENS_SECRET_ARN = var.source_tokens_secret_arn
    CANARY_SOURCE            = "canary"
    CANARY_REGION            = var.canary_target_region
  }

  log_retention_days = var.log_retention_days
  tags               = var.tags
}

resource "aws_cloudwatch_event_rule" "canary" {
  count = var.enable_canary ? 1 : 0

  name                = "${var.name}-ingress-canary"
  description         = "Ingress synthetic heartbeat"
  schedule_expression = var.canary_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "canary" {
  count = var.enable_canary ? 1 : 0

  rule = aws_cloudwatch_event_rule.canary[0].name
  arn  = module.canary[0].function_arn
}

resource "aws_lambda_permission" "canary" {
  count = var.enable_canary ? 1 : 0

  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.canary[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary[0].arn
}

# The canary's own success metric. In Phase 3 the Tokyo PRIMARY record uses
# the Osaka stack's instance of this alarm as its Route 53 health check.
resource "aws_cloudwatch_metric_alarm" "canary_posted" {
  count = var.enable_canary ? 1 : 0

  alarm_name          = "${var.name}-canary-posted"
  alarm_description   = "Canary in ${data.aws_region.current.region} could not post to the ingress at ${var.canary_target_alerts_url}"
  namespace           = var.metrics_namespace
  metric_name         = "CanaryPosted"
  dimensions          = { Region = data.aws_region.current.region, canary_region = var.canary_target_region }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = var.tags
}
