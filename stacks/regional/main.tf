# Regional stack: everything the alert pipeline needs in ONE region.
# Tokyo (role = primary) and Osaka (role = secondary) apply the same root
# module with different tfvars. See docs/architecture.md for the flow and
# docs/adr/ for the rulings behind each choice.

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

locals {
  is_primary = var.role == "primary"

  tags = merge(
    {
      Project     = var.name
      Environment = var.environment
      Role        = var.role
      ManagedBy   = "terraform"
    },
    var.extra_tags,
  )

  build_dir = "${path.root}/.build"
  src_dir   = "${path.root}/../../src/lambda"

  alerts_url = "https://${var.ingress_domain_name}/v1/alerts"
}

# ---- Foundation -----------------------------------------------------------------------------

module "kms" {
  source = "../../modules/kms"

  name        = var.name
  description = "${var.name} (${var.region}): queues, Journal, secrets, logs, Keep data"
  tags        = local.tags
}

module "network" {
  source = "../../modules/network"

  name                       = var.name
  cidr_block                 = var.vpc_cidr
  enable_interface_endpoints = var.enable_interface_endpoints
  kms_key_arn                = module.kms.key_arn
  flow_log_retention_days    = var.log_retention_days
  tags                       = local.tags
}

module "queues" {
  source = "../../modules/queues"

  name_prefix = var.name
  kms_key_arn = module.kms.key_arn
  tags        = local.tags
}

module "journal" {
  source = "../../modules/journal"

  create          = local.is_primary
  name_prefix     = var.name
  kms_key_arn     = module.kms.key_arn
  replicas        = local.is_primary ? var.journal_replicas : {}
  routing_entries = var.routing_entries
  tags            = local.tags
}

module "layer" {
  source = "../../modules/lambda_layer"

  name       = "${var.name}-common"
  source_dir = "${local.src_dir}/layer"
  build_dir  = local.build_dir
}

# On-failure destination for the schedule-driven functions (Phase 2).
resource "aws_sqs_queue" "async_dlq" {
  name                      = "${var.name}-async-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = module.kms.key_arn
  tags                      = local.tags
}

# ---- Secrets ---------------------------------------------------------------------------------

# One random token per source. Operators read them from Secrets Manager and
# configure the sources; the authorizer validates them.
resource "random_password" "source_token" {
  for_each = toset(var.alert_sources)

  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "source_tokens" {
  name        = "${var.name}/ingress/source-tokens"
  description = "Per-source tokens accepted by the ingress authorizer ({source: token})"
  kms_key_id  = module.kms.key_arn

  dynamic "replica" {
    for_each = toset(local.is_primary ? var.secret_replica_regions : [])
    content {
      region = replica.value
    }
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "source_tokens" {
  secret_id     = aws_secretsmanager_secret.source_tokens.id
  secret_string = jsonencode({ for s, p in random_password.source_token : s => p.result })
}

# Communication tool credentials. Terraform seeds the shape; the auth value is
# written out-of-band (aws secretsmanager put-secret-value) and never in Git.
resource "aws_secretsmanager_secret" "comm_tool" {
  name        = "${var.name}/router/communication-tool"
  description = "Webhook URL and auth header for the in-house communication tool"
  kms_key_id  = module.kms.key_arn

  dynamic "replica" {
    for_each = toset(local.is_primary ? var.secret_replica_regions : [])
    content {
      region = replica.value
    }
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "comm_tool" {
  secret_id = aws_secretsmanager_secret.comm_tool.id

  secret_string = jsonencode({
    webhook_url = var.comm_tool_webhook_url
    auth_header = "Authorization"
    auth_value  = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---- Ingress ------------------------------------------------------------------------------------

module "certificate" {
  source = "../../modules/acm_certificate"

  domain_name = var.ingress_domain_name
  zone_id     = data.aws_route53_zone.public.zone_id
  tags        = local.tags
}

module "ingress" {
  source = "../../modules/ingress"

  name                           = var.name
  ingress_queue                  = module.queues.ingress
  kms_key_arn                    = module.kms.key_arn
  authorizer_source_dir          = "${local.src_dir}/authorizer"
  build_dir                      = local.build_dir
  source_tokens_secret_arn       = aws_secretsmanager_secret.source_tokens.arn
  throttling_rate_limit          = var.api_throttling_rate_limit
  throttling_burst_limit         = var.api_throttling_burst_limit
  domain_name                    = var.ingress_domain_name
  certificate_arn                = module.certificate.certificate_arn
  source_ip_allowlists           = var.source_ip_allowlists
  manage_account_cloudwatch_role = var.manage_api_gateway_account_role
  log_retention_days             = var.log_retention_days
  tags                           = local.tags
}

module "dns" {
  source = "../../modules/dns_record"

  zone_id        = data.aws_route53_zone.public.zone_id
  name           = var.ingress_domain_name
  alias_name     = module.ingress.regional_domain_name
  alias_zone_id  = module.ingress.regional_zone_id
  failover_role  = var.dns_failover_role
  set_identifier = var.region

  health_check = var.dns_failover_role == null ? null : (
    var.dns_health_check.type == "https" ? {
      type          = "https"
      fqdn          = module.ingress.execution_endpoint
      resource_path = "/${module.ingress.stage_name}/healthz"
      } : {
      type         = "cloudwatch_alarm"
      alarm_name   = var.dns_health_check.alarm_name
      alarm_region = var.dns_health_check.alarm_region
    }
  )

  tags = local.tags
}

# ---- Normalize -------------------------------------------------------------------------------------

data "aws_iam_policy_document" "normalize" {
  statement {
    sid       = "Journal"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [module.journal.journal_table_arn]
  }

  statement {
    sid       = "Fanout"
    actions   = ["sqs:SendMessage"]
    resources = [module.queues.alerts_fifo.arn, module.queues.keep_delivery_fifo.arn]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [module.kms.key_arn]
  }
}

module "normalize" {
  source = "../../modules/lambda_function"

  function_name = "${var.name}-normalize"
  description   = "ingress.standard -> Journal -> alerts.fifo (critical) + keep-delivery.fifo"
  source_dir    = "${local.src_dir}/normalize"
  build_dir     = local.build_dir
  layers        = [module.layer.arn]
  memory_size   = 256
  timeout       = 30
  kms_key_arn   = module.kms.key_arn
  policy_json   = data.aws_iam_policy_document.normalize.json

  environment = {
    JOURNAL_TABLE          = module.journal.journal_table_name
    ALERTS_FIFO_URL        = module.queues.alerts_fifo.url
    KEEP_DELIVERY_FIFO_URL = module.queues.keep_delivery_fifo.url
    CRITICAL_SEVERITIES    = join(",", var.critical_severities)
    SEVERITY_LABEL         = var.severity_label
    SERVICE_LABEL          = var.service_label
  }

  sqs_event_source = {
    queue_arn                          = module.queues.ingress.arn
    batch_size                         = 10
    maximum_batching_window_in_seconds = 0
  }

  log_retention_days = var.log_retention_days
  tags               = local.tags
}

# ---- Keep ------------------------------------------------------------------------------------------

module "keep_datastore" {
  source = "../../modules/keep_datastore"

  name                          = var.name
  vpc_id                        = module.network.vpc_id
  data_subnet_ids               = module.network.data_subnet_ids
  kms_key_arn                   = module.kms.key_arn
  db_role                       = local.is_primary ? "primary" : "replica"
  db_replicate_source_arn       = var.keep_db_replicate_source_arn
  db_password_source_secret_arn = var.keep_db_password_source_secret_arn
  db_instance_class             = var.keep_db_instance_class
  db_multi_az                   = var.keep_db_multi_az
  secret_replica_regions        = local.is_primary ? var.secret_replica_regions : []
  create_redis                  = var.keep_create_redis
  redis_node_type               = var.keep_redis_node_type
  tags                          = local.tags
}

module "keep" {
  source = "../../modules/keep_service"

  name                    = var.name
  vpc_id                  = module.network.vpc_id
  vpc_cidr_block          = module.network.vpc_cidr_block
  private_subnet_ids      = module.network.private_subnet_ids
  kms_key_arn             = module.kms.key_arn
  keep_image_tag          = var.keep_image_tag
  api_desired_count       = var.keep_api_desired_count
  ui_desired_count        = var.keep_ui_desired_count
  db_secret_arn           = module.keep_datastore.db_secret_arn
  db_security_group_id    = module.keep_datastore.db_security_group_id
  alerts_fifo             = { arn = module.queues.alerts_fifo.arn, url = module.queues.alerts_fifo.url }
  keep_extra_environment  = var.keep_extra_environment
  ecr_replication_regions = local.is_primary ? var.ecr_replication_regions : []
  secret_replica_regions  = local.is_primary ? var.secret_replica_regions : []
  app_secret_source_arn   = var.keep_app_secret_source_arn
  log_retention_days      = var.log_retention_days
  tags                    = local.tags

  redis = var.keep_create_redis ? {
    host              = module.keep_datastore.redis_endpoint
    port              = module.keep_datastore.redis_port
    security_group_id = module.keep_datastore.redis_security_group_id
  } : null
}

module "keep_dispatcher" {
  source = "../../modules/keep_dispatcher"

  name                    = var.name
  vpc_id                  = module.network.vpc_id
  private_subnet_ids      = module.network.private_subnet_ids
  alb_security_group_id   = module.keep.alb_security_group_id
  keep_api_url            = module.keep.keep_api_url
  keep_api_port           = module.keep.api_port
  keep_app_secret_arn     = module.keep.app_secret_arn
  keep_delivery_queue_arn = module.queues.keep_delivery_fifo.arn
  journal_table_arn       = module.journal.journal_table_arn
  journal_table_name      = module.journal.journal_table_name
  kms_key_arn             = module.kms.key_arn
  source_dir              = "${local.src_dir}/keep_dispatcher"
  build_dir               = local.build_dir
  layer_arns              = [module.layer.arn]
  log_retention_days      = var.log_retention_days
  tags                    = local.tags
}

# ---- Routing tool (内製ツール v1) ------------------------------------------------------------------

data "aws_iam_policy_document" "router" {
  statement {
    sid       = "ClaimNotification"
    actions   = ["dynamodb:UpdateItem"]
    resources = [module.journal.journal_table_arn]
  }

  statement {
    sid       = "ReadRouting"
    actions   = ["dynamodb:GetItem"]
    resources = [module.journal.routing_table_arn]
  }

  statement {
    sid       = "CommToolCredentials"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.comm_tool.arn]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [module.kms.key_arn]
  }
}

module "router" {
  source = "../../modules/lambda_function"

  function_name = "${var.name}-router"
  description   = "alerts.fifo -> Journal claim -> room lookup -> communication tool"
  source_dir    = "${local.src_dir}/router"
  build_dir     = local.build_dir
  layers        = [module.layer.arn]
  memory_size   = 256
  timeout       = 30
  kms_key_arn   = module.kms.key_arn
  policy_json   = data.aws_iam_policy_document.router.json

  environment = {
    JOURNAL_TABLE        = module.journal.journal_table_name
    ROUTING_TABLE        = module.journal.routing_table_name
    COMM_TOOL_SECRET_ARN = aws_secretsmanager_secret.comm_tool.arn
  }

  sqs_event_source = {
    queue_arn                          = module.queues.alerts_fifo.arn
    batch_size                         = 10
    maximum_batching_window_in_seconds = 0
  }

  log_retention_days = var.log_retention_days
  tags               = local.tags
}

# ---- Phase 2: Reconciler, heartbeats, alarms, independent path -------------------------------------

module "observability" {
  count  = var.enable_phase2 ? 1 : 0
  source = "../../modules/observability"

  name                       = var.name
  kms_key_arn                = module.kms.key_arn
  escalation_emails          = var.escalation_emails
  escalation_sms_numbers     = var.escalation_sms_numbers
  escalation_https_endpoints = var.escalation_https_endpoints

  dlqs = {
    ingress       = module.queues.ingress.dlq_name
    alerts        = module.queues.alerts_fifo.dlq_name
    keep-delivery = module.queues.keep_delivery_fifo.dlq_name
    async         = aws_sqs_queue.async_dlq.name
  }

  queues = {
    ingress       = { name = module.queues.ingress.name, max_age_sec = 300 }
    alerts        = { name = module.queues.alerts_fifo.name, max_age_sec = 300 }
    keep-delivery = { name = module.queues.keep_delivery_fifo.name, max_age_sec = 1800 }
  }

  lambda_function_names = {
    normalize  = module.normalize.function_name
    router     = module.router.function_name
    dispatcher = module.keep_dispatcher.function_name
    authorizer = module.ingress.authorizer_function_name
  }

  rest_api_name                    = var.name
  rest_api_stage                   = module.ingress.stage_name
  keep_alb_arn_suffix              = module.keep.alb_arn_suffix
  keep_api_target_group_arn_suffix = module.keep.api_target_group_arn_suffix

  enable_canary            = var.enable_canary
  canary_target_alerts_url = local.alerts_url
  canary_target_region     = var.region
  source_tokens_secret_arn = aws_secretsmanager_secret.source_tokens.arn

  source_dir         = "${local.src_dir}/canary"
  build_dir          = local.build_dir
  layer_arns         = [module.layer.arn]
  async_dlq_arn      = aws_sqs_queue.async_dlq.arn
  log_retention_days = var.log_retention_days
  tags               = local.tags
}

module "reconciler" {
  count  = var.enable_phase2 ? 1 : 0
  source = "../../modules/reconciler"

  name                      = var.name
  journal                   = { name = module.journal.journal_table_name, arn = module.journal.journal_table_arn }
  keep_delivery_fifo        = { arn = module.queues.keep_delivery_fifo.arn, url = module.queues.keep_delivery_fifo.url }
  independent_sns_topic_arn = module.observability[0].independent_sns_topic_arn
  keep_pending_minutes      = var.reconciler_keep_pending_minutes
  notify_pending_minutes    = var.reconciler_notify_pending_minutes
  kms_key_arn               = module.kms.key_arn
  source_dir                = "${local.src_dir}/reconciler"
  build_dir                 = local.build_dir
  layer_arns                = [module.layer.arn]
  async_dlq_arn             = aws_sqs_queue.async_dlq.arn
  log_retention_days        = var.log_retention_days
  tags                      = local.tags
}
