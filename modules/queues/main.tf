# Three queues, each with a DLQ:
#   ingress          (Standard) : raw payloads from API Gateway. Standard so that the
#                                 public edge never blocks on FIFO throughput limits.
#   alerts.fifo      (FIFO)     : the ONLY contract surface towards the routing tool.
#                                 Producers: Normalize Lambda (source=direct) and Keep (source=keep).
#   keep-delivery.fifo (FIFO)   : durable hand-off to Keep. Consumed by the Dispatcher Lambda.
# MessageGroupId = fingerprint, MessageDeduplicationId = transition_id (set by producers,
# so content_based_deduplication stays off).

locals {
  fifo_queues = {
    alerts        = "${var.name_prefix}-alerts"
    keep_delivery = "${var.name_prefix}-keep-delivery"
  }
}

# ---- ingress (Standard) ------------------------------------------------------

resource "aws_sqs_queue" "ingress_dlq" {
  name                      = "${var.name_prefix}-ingress-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  kms_master_key_id         = var.kms_key_arn
  tags                      = var.tags
}

resource "aws_sqs_queue" "ingress" {
  name                       = "${var.name_prefix}-ingress"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.ingress_visibility_timeout_seconds
  kms_master_key_id          = var.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingress_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "ingress_dlq" {
  queue_url = aws_sqs_queue.ingress_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingress.arn]
  })
}

# ---- FIFO queues -------------------------------------------------------------

resource "aws_sqs_queue" "fifo_dlq" {
  for_each = local.fifo_queues

  name                      = "${each.value}-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = var.dlq_retention_seconds
  kms_master_key_id         = var.kms_key_arn
  tags                      = var.tags
}

resource "aws_sqs_queue" "fifo" {
  for_each = local.fifo_queues

  name                        = "${each.value}.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  deduplication_scope         = "messageGroup"
  fifo_throughput_limit       = "perMessageGroupId"
  message_retention_seconds   = var.message_retention_seconds
  visibility_timeout_seconds  = var.fifo_visibility_timeout_seconds
  kms_master_key_id           = var.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.fifo_dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "fifo_dlq" {
  for_each = local.fifo_queues

  queue_url = aws_sqs_queue.fifo_dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.fifo[each.key].arn]
  })
}
