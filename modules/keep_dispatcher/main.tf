# keep-delivery.fifo -> Keep API (push). The only Lambda inside the VPC. Its
# success is independent of the critical path: a Keep outage just leaves the
# messages in the queue (14 days) and the Reconciler re-drives anything Keep
# accepted (202) but never persisted.

resource "aws_security_group" "this" {
  name        = "${var.name}-keep-dispatcher"
  description = "Keep Dispatcher Lambda"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-keep-dispatcher" })
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Keep ALB, DynamoDB/Secrets Manager via endpoints or NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_dispatcher" {
  security_group_id            = var.alb_security_group_id
  description                  = "Keep API from Dispatcher"
  referenced_security_group_id = aws_security_group.this.id
  from_port                    = var.keep_api_port
  to_port                      = var.keep_api_port
  ip_protocol                  = "tcp"
}

data "aws_iam_policy_document" "this" {
  statement {
    sid       = "UpdateJournalKeepStatus"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.journal_table_arn]
  }

  statement {
    sid       = "ReadKeepApiKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.keep_app_secret_arn]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

module "function" {
  source = "../lambda_function"

  function_name = "${var.name}-keep-dispatcher"
  description   = "Pushes normalized alerts from keep-delivery.fifo to the Keep API"
  source_dir    = var.source_dir
  build_dir     = var.build_dir
  layers        = var.layer_arns
  memory_size   = 256
  timeout       = 30
  kms_key_arn   = var.kms_key_arn
  policy_json   = data.aws_iam_policy_document.this.json

  environment = {
    KEEP_API_URL        = var.keep_api_url
    KEEP_APP_SECRET_ARN = var.keep_app_secret_arn
    KEEP_PROVIDER_TYPE  = "keep"
    JOURNAL_TABLE       = var.journal_table_name
  }

  vpc_config = {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.this.id]
  }

  sqs_event_source = {
    queue_arn                          = var.keep_delivery_queue_arn
    batch_size                         = 10
    maximum_batching_window_in_seconds = 1
    maximum_concurrency                = 4
  }

  log_retention_days = var.log_retention_days
  tags               = var.tags
}
