# Opinionated Lambda wrapper: zip from source_dir, least-privilege role built
# from an inline policy document, explicit KMS-encrypted log group, JSON
# structured logging, optional VPC attachment and SQS event source mapping
# with partial batch failure reporting.

data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${var.build_dir}/${var.function_name}.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc", "**/tests/**"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name_prefix        = substr("${var.function_name}-", 0, 38)
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count = var.vpc_config == null ? 0 : 1

  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "custom" {
  count = var.policy_json == null ? 0 : 1

  name   = "function"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}

data "aws_iam_policy_document" "sqs_source" {
  count = var.sqs_event_source == null ? 0 : 1

  statement {
    sid = "ConsumeSourceQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.sqs_event_source.queue_arn]
  }

  statement {
    sid       = "DecryptSourceQueue"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "sqs_source" {
  count = var.sqs_event_source == null ? 0 : 1

  name   = "sqs-event-source"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.sqs_source[0].json
}

data "aws_iam_policy_document" "dlq" {
  count = var.dead_letter_queue_arn == null ? 0 : 1

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [var.dead_letter_queue_arn]
  }

  statement {
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "dlq" {
  count = var.dead_letter_queue_arn == null ? 0 : 1

  name   = "async-dlq"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.dlq[0].json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  description   = var.description
  role          = aws_iam_role.this.arn
  handler       = var.handler
  runtime       = var.runtime
  architectures = [var.architecture]
  memory_size   = var.memory_size
  timeout       = var.timeout
  layers        = var.layers

  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  reserved_concurrent_executions = var.reserved_concurrent_executions
  kms_key_arn                    = var.kms_key_arn

  environment {
    variables = var.environment
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "WARN"
    log_group             = aws_cloudwatch_log_group.this.name
  }

  tracing_config {
    mode = "Active"
  }

  dynamic "vpc_config" {
    for_each = var.vpc_config == null ? [] : [var.vpc_config]
    content {
      subnet_ids         = vpc_config.value.subnet_ids
      security_group_ids = vpc_config.value.security_group_ids
    }
  }

  dynamic "dead_letter_config" {
    for_each = var.dead_letter_queue_arn == null ? [] : [var.dead_letter_queue_arn]
    content {
      target_arn = dead_letter_config.value
    }
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.basic,
    aws_iam_role_policy_attachment.vpc,
    aws_iam_role_policy.custom,
    aws_iam_role_policy.sqs_source,
    aws_cloudwatch_log_group.this,
  ]
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_lambda_event_source_mapping" "sqs" {
  count = var.sqs_event_source == null ? 0 : 1

  event_source_arn                   = var.sqs_event_source.queue_arn
  function_name                      = aws_lambda_function.this.arn
  batch_size                         = var.sqs_event_source.batch_size
  maximum_batching_window_in_seconds = var.sqs_event_source.maximum_batching_window_in_seconds
  function_response_types            = ["ReportBatchItemFailures"]

  dynamic "scaling_config" {
    for_each = var.sqs_event_source.maximum_concurrency == null ? [] : [var.sqs_event_source.maximum_concurrency]
    content {
      maximum_concurrency = scaling_config.value
    }
  }

  depends_on = [aws_iam_role_policy.sqs_source]
}
