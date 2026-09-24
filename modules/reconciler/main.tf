# Scheduled Lambda that closes the two gaps Keep's 202 leaves open:
#   Journal -> Keep : re-enqueue transitions Keep never confirmed
#   Journal -> 通知 : escalate critical transitions nobody delivered, on the SNS path
#                    that does not depend on the routing tool or the communication tool.

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "QueryAndUpdateJournal"
    actions   = ["dynamodb:Query", "dynamodb:UpdateItem"]
    resources = [var.journal.arn, "${var.journal.arn}/index/*"]
  }

  statement {
    sid       = "RedeliverToKeep"
    actions   = ["sqs:SendMessage"]
    resources = [var.keep_delivery_fifo.arn]
  }

  statement {
    sid       = "Escalate"
    actions   = ["sns:Publish"]
    resources = [var.independent_sns_topic_arn]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

module "function" {
  source = "../lambda_function"

  function_name = "${var.name}-reconciler"
  description   = "Re-drives Keep delivery and escalates undelivered critical alerts from the Journal"
  source_dir    = var.source_dir
  build_dir     = var.build_dir
  layers        = var.layer_arns
  memory_size   = 256
  timeout       = 120
  kms_key_arn   = var.kms_key_arn
  policy_json   = data.aws_iam_policy_document.this.json

  reserved_concurrent_executions = 1
  dead_letter_queue_arn          = var.async_dlq_arn

  environment = {
    JOURNAL_TABLE             = var.journal.name
    KEEP_DELIVERY_FIFO_URL    = var.keep_delivery_fifo.url
    INDEPENDENT_SNS_TOPIC_ARN = var.independent_sns_topic_arn
    KEEP_PENDING_MINUTES      = tostring(var.keep_pending_minutes)
    NOTIFY_PENDING_MINUTES    = tostring(var.notify_pending_minutes)
  }

  log_retention_days = var.log_retention_days
  tags               = var.tags
}

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.name}-reconciler"
  description         = "Run the Journal reconciler"
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  rule = aws_cloudwatch_event_rule.schedule.name
  arn  = module.function.function_arn

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 2
  }
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
