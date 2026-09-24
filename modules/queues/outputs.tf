output "ingress" {
  description = "ingress.standard queue (arn, url, name) and its DLQ."
  value = {
    arn      = aws_sqs_queue.ingress.arn
    url      = aws_sqs_queue.ingress.id
    name     = aws_sqs_queue.ingress.name
    dlq_arn  = aws_sqs_queue.ingress_dlq.arn
    dlq_name = aws_sqs_queue.ingress_dlq.name
  }
}

output "alerts_fifo" {
  description = "alerts.fifo queue (arn, url, name) and its DLQ."
  value = {
    arn      = aws_sqs_queue.fifo["alerts"].arn
    url      = aws_sqs_queue.fifo["alerts"].id
    name     = aws_sqs_queue.fifo["alerts"].name
    dlq_arn  = aws_sqs_queue.fifo_dlq["alerts"].arn
    dlq_name = aws_sqs_queue.fifo_dlq["alerts"].name
  }
}

output "keep_delivery_fifo" {
  description = "keep-delivery.fifo queue (arn, url, name) and its DLQ."
  value = {
    arn      = aws_sqs_queue.fifo["keep_delivery"].arn
    url      = aws_sqs_queue.fifo["keep_delivery"].id
    name     = aws_sqs_queue.fifo["keep_delivery"].name
    dlq_arn  = aws_sqs_queue.fifo_dlq["keep_delivery"].arn
    dlq_name = aws_sqs_queue.fifo_dlq["keep_delivery"].name
  }
}
