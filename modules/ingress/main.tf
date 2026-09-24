# Public receiving edge.
#   https://<domain>/v1/alerts/{source}  POST  -> ingress.standard (SQS SendMessage, no Lambda in the path)
#   https://<domain>/healthz             GET   -> mock 200 (Route 53 health checks)
# Ruling (ADR-0002): REST API instead of HTTP API because WAFv2 can only be
# associated with a REST API stage, and the spec requires WAF IP allow lists.
# The Lambda REQUEST authorizer validates a per-source token stored in
# Secrets Manager and returns a policy scoped to that source's path only, so
# the authorizer cache (keyed by token) cannot leak access across sources.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---- Authorizer ----------------------------------------------------------------

data "aws_iam_policy_document" "authorizer" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.source_tokens_secret_arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

module "authorizer" {
  source = "../lambda_function"

  function_name = "${var.name}-authorizer"
  description   = "Validates per-source alert tokens for the ingress API"
  source_dir    = var.authorizer_source_dir
  build_dir     = var.build_dir
  memory_size   = 128
  timeout       = 5
  kms_key_arn   = var.kms_key_arn
  policy_json   = data.aws_iam_policy_document.authorizer.json

  environment = {
    SOURCE_TOKENS_SECRET_ARN = var.source_tokens_secret_arn
    TOKEN_HEADER             = "x-alert-token"
  }

  log_retention_days = var.log_retention_days
  tags               = var.tags
}

# ---- REST API ------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name        = var.name
  description = "Alert ingress: durable hand-off to SQS"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

resource "aws_api_gateway_authorizer" "token" {
  name                             = "source-token"
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  type                             = "REQUEST"
  authorizer_uri                   = module.authorizer.invoke_arn
  identity_source                  = "method.request.header.X-Alert-Token"
  authorizer_result_ttl_in_seconds = 300
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/${aws_api_gateway_authorizer.token.id}"
}

resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "v1"
}

resource "aws_api_gateway_resource" "alerts" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "alerts"
}

resource "aws_api_gateway_resource" "source" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.alerts.id
  path_part   = "{source}"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.source.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.token.id

  request_parameters = {
    "method.request.path.source"          = true
    "method.request.header.X-Alert-Token" = true
  }
}

# Role API Gateway assumes to call SQS.
data "aws_iam_policy_document" "apigw_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "apigw_sqs" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [var.ingress_queue.arn]
  }

  statement {
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "apigw_sqs" {
  name_prefix        = "${var.name}-apigw-"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "apigw_sqs" {
  name   = "send-to-ingress"
  role   = aws_iam_role.apigw_sqs.id
  policy = data.aws_iam_policy_document.apigw_sqs.json
}

locals {
  # Whole request body becomes the SQS message; the {source} path segment,
  # the API Gateway request id and the receive time travel as message attributes.
  sqs_request_template = join("&", [
    "Action=SendMessage",
    "MessageBody=$util.urlEncode($input.body)",
    "MessageAttribute.1.Name=source",
    "MessageAttribute.1.Value.StringValue=$util.urlEncode($input.params('source'))",
    "MessageAttribute.1.Value.DataType=String",
    "MessageAttribute.2.Name=request_id",
    "MessageAttribute.2.Value.StringValue=$context.requestId",
    "MessageAttribute.2.Value.DataType=String",
    "MessageAttribute.3.Name=received_at_epoch_ms",
    "MessageAttribute.3.Value.StringValue=$context.requestTimeEpoch",
    "MessageAttribute.3.Value.DataType=String",
  ])

  content_types = ["application/json", "text/plain", "application/x-www-form-urlencoded"]
}

resource "aws_api_gateway_integration" "sqs" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.source.id
  http_method             = aws_api_gateway_method.post.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.region}:sqs:path/${data.aws_caller_identity.current.account_id}/${var.ingress_queue.name}"
  credentials             = aws_iam_role.apigw_sqs.arn
  passthrough_behavior    = "NEVER"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = { for ct in local.content_types : ct => local.sqs_request_template }
}

resource "aws_api_gateway_method_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "202"

  response_models = { "application/json" = "Empty" }
}

resource "aws_api_gateway_method_response" "bad_request" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "400"

  response_models = { "application/json" = "Error" }
}

resource "aws_api_gateway_method_response" "unavailable" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "503"

  response_models = { "application/json" = "Error" }
}

resource "aws_api_gateway_integration_response" "accepted" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.source.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = aws_api_gateway_method_response.accepted.status_code

  response_templates = {
    "application/json" = "{\"status\":\"accepted\",\"request_id\":\"$context.requestId\"}"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_integration_response" "bad_request" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.source.id
  http_method       = aws_api_gateway_method.post.http_method
  status_code       = aws_api_gateway_method_response.bad_request.status_code
  selection_pattern = "4\\d{2}"

  response_templates = {
    "application/json" = "{\"status\":\"rejected\",\"request_id\":\"$context.requestId\"}"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

resource "aws_api_gateway_integration_response" "unavailable" {
  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.source.id
  http_method       = aws_api_gateway_method.post.http_method
  status_code       = aws_api_gateway_method_response.unavailable.status_code
  selection_pattern = "5\\d{2}"

  response_templates = {
    "application/json" = "{\"status\":\"unavailable\",\"request_id\":\"$context.requestId\"}"
  }

  depends_on = [aws_api_gateway_integration.sqs]
}

# ---- /healthz (mock) for Route 53 health checks ----------------------------------

resource "aws_api_gateway_resource" "healthz" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "healthz"
}

resource "aws_api_gateway_method" "healthz" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.healthz.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "healthz" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.healthz.id
  http_method = aws_api_gateway_method.healthz.http_method
  type        = "MOCK"

  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "healthz" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.healthz.id
  http_method = aws_api_gateway_method.healthz.http_method
  status_code = "200"

  response_models = { "application/json" = "Empty" }
}

resource "aws_api_gateway_integration_response" "healthz" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.healthz.id
  http_method = aws_api_gateway_method.healthz.http_method
  status_code = aws_api_gateway_method_response.healthz.status_code

  response_templates = { "application/json" = "{\"status\":\"ok\"}" }

  depends_on = [aws_api_gateway_integration.healthz]
}

# ---- Deployment / stage ----------------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.v1,
      aws_api_gateway_resource.alerts,
      aws_api_gateway_resource.source,
      aws_api_gateway_method.post,
      aws_api_gateway_integration.sqs,
      aws_api_gateway_integration_response.accepted,
      aws_api_gateway_integration_response.bad_request,
      aws_api_gateway_integration_response.unavailable,
      aws_api_gateway_resource.healthz,
      aws_api_gateway_method.healthz,
      aws_api_gateway_integration.healthz,
      aws_api_gateway_integration_response.healthz,
      aws_api_gateway_authorizer.token,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}/access"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = var.stage_name
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId         = "$context.requestId"
      requestTime       = "$context.requestTime"
      sourceIp          = "$context.identity.sourceIp"
      httpMethod        = "$context.httpMethod"
      path              = "$context.path"
      status            = "$context.status"
      responseLength    = "$context.responseLength"
      integrationStatus = "$context.integration.status"
      authorizerStatus  = "$context.authorizer.status"
      wafStatus         = "$context.wafResponseCode"
      errorMessage      = "$context.error.message"
    })
  }

  tags = var.tags

  depends_on = [aws_api_gateway_account.this]
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
    metrics_enabled        = true
    logging_level          = "ERROR"
    data_trace_enabled     = false
  }
}

# Account-level CloudWatch role (required once per account/region for stage logging).
data "aws_iam_policy_document" "apigw_logs_assume" {
  count = var.manage_account_cloudwatch_role ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_logs" {
  count = var.manage_account_cloudwatch_role ? 1 : 0

  name_prefix        = "${var.name}-apigw-logs-"
  assume_role_policy = data.aws_iam_policy_document.apigw_logs_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "apigw_logs" {
  count = var.manage_account_cloudwatch_role ? 1 : 0

  role       = aws_iam_role.apigw_logs[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count = var.manage_account_cloudwatch_role ? 1 : 0

  cloudwatch_role_arn = aws_iam_role.apigw_logs[0].arn

  depends_on = [aws_iam_role_policy_attachment.apigw_logs]
}

# ---- Custom domain ----------------------------------------------------------------

resource "aws_api_gateway_domain_name" "this" {
  domain_name              = var.domain_name
  regional_certificate_arn = var.certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

# ---- WAF -------------------------------------------------------------------------

resource "aws_wafv2_ip_set" "source" {
  for_each = var.source_ip_allowlists

  name               = "${var.name}-${each.key}"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = each.value
  tags               = var.tags
}

resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # One rule per source with a published IP range: block requests to that
  # source's path unless they come from the allow list.
  dynamic "rule" {
    for_each = var.source_ip_allowlists
    content {
      name     = "allowlist-${rule.key}"
      priority = 10 + index(sort(keys(var.source_ip_allowlists)), rule.key)

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              search_string         = "/alerts/${rule.key}"
              positional_constraint = "CONTAINS"

              field_to_match {
                uri_path {}
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }

          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.source[rule.key].arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "allowlist-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_api_gateway_stage.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}
