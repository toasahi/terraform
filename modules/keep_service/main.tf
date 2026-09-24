# Keep on ECS Fargate (x86, 2 AZs) behind an internal ALB.
#   :8080 -> keep-api   (Dispatcher Lambda, UI server side, /healthcheck)
#   :80   -> keep-ui    (operators inside the VPC / via VPN)
# Provider configuration is injected with KEEP_PROVIDERS (JSON, no secrets:
# the task role authenticates to SQS). Workflows are baked into the mirrored
# image under /opt/keep/workflows (KEEP_WORKFLOWS_DIRECTORY), so Git is the
# only place either is edited. Keep API keys / JWT secret / admin password are
# generated here and stored in one Secrets Manager secret.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  create_app_secret = var.app_secret_source_arn == null
  api_port          = 8080
  ui_port           = 3000
  workflows_dir     = "/opt/keep/workflows"

  ecr_repositories = {
    api = "${var.name}/keep-api"
    ui  = "${var.name}/keep-ui"
  }

  keep_providers = {
    "alerts-fifo" = {
      type = "amazonsqs"
      authentication = {
        region_name   = data.aws_region.current.region
        sqs_queue_url = var.alerts_fifo.url
      }
    }
  }
}

# ---- ECR (mirror of the upstream Keep images) --------------------------------

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_replication_configuration" "this" {
  count = length(var.ecr_replication_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = toset(var.ecr_replication_regions)
        content {
          region      = destination.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }

      repository_filter {
        filter      = "${var.name}/keep-"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

# ---- Application secret -------------------------------------------------------

resource "random_password" "api_key" {
  count   = local.create_app_secret ? 1 : 0
  length  = 48
  special = false
}

resource "random_password" "jwt_secret" {
  count   = local.create_app_secret ? 1 : 0
  length  = 64
  special = false
}

resource "random_password" "admin_password" {
  count            = local.create_app_secret ? 1 : 0
  length           = 24
  special          = true
  override_special = "!#%^*-_=+"
}

resource "random_password" "nextauth_secret" {
  count   = local.create_app_secret ? 1 : 0
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  count = local.create_app_secret ? 1 : 0

  name        = "${var.name}/keep/app"
  description = "Keep application credentials (API key for the Dispatcher, JWT secret, admin password, NextAuth secret)"
  kms_key_id  = var.kms_key_arn

  dynamic "replica" {
    for_each = toset(var.secret_replica_regions)
    content {
      region = replica.value
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "app" {
  count = local.create_app_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.app[0].id

  secret_string = jsonencode({
    api_key               = random_password.api_key[0].result
    keep_default_api_keys = "dispatcher:webhook:${random_password.api_key[0].result}"
    jwt_secret            = random_password.jwt_secret[0].result
    admin_username        = "keep"
    admin_password        = random_password.admin_password[0].result
    nextauth_secret       = random_password.nextauth_secret[0].result
  })
}

locals {
  app_secret_arn = local.create_app_secret ? aws_secretsmanager_secret.app[0].arn : var.app_secret_source_arn
}

# ---- Security groups ------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-keep-alb"
  description = "Internal ALB in front of Keep"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-keep-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc" {
  for_each = { ui = 80, api = local.api_port }

  security_group_id = aws_security_group.alb.id
  description       = "Keep ${each.key} listener from inside the VPC"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "To tasks"
  cidr_ipv4         = var.vpc_cidr_block
  ip_protocol       = "-1"
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-keep-tasks"
  description = "Keep ECS tasks"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-keep-tasks" })
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  for_each = { api = local.api_port, ui = local.ui_port }

  security_group_id            = aws_security_group.tasks.id
  description                  = "Keep ${each.key} from ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound (AWS APIs via Regional NAT / endpoints, RDS, Redis)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_tasks" {
  security_group_id            = var.db_security_group_id
  description                  = "PostgreSQL from Keep tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_tasks" {
  count = var.redis == null ? 0 : 1

  security_group_id            = var.redis.security_group_id
  description                  = "Redis from Keep tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  from_port                    = var.redis.port
  to_port                      = var.redis.port
  ip_protocol                  = "tcp"
}

# ---- ALB --------------------------------------------------------------------------

resource "aws_lb" "this" {
  name                       = "${var.name}-keep"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.private_subnet_ids
  drop_invalid_header_fields = true
  idle_timeout               = 120

  tags = var.tags
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name}-keep-api"
  port        = local.api_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/healthcheck"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_target_group" "ui" {
  name        = "${var.name}-keep-ui"
  port        = local.ui_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.api_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  tags = var.tags
}

resource "aws_lb_listener" "ui" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }

  tags = var.tags
}

locals {
  keep_api_url = "http://${aws_lb.this.dns_name}:${local.api_port}"
  keep_ui_url  = "http://${aws_lb.this.dns_name}"
}

# ---- IAM ----------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${var.name}-keep-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn, local.app_secret_arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Task role of keep-api: the only thing Keep may do in AWS is write alerts.fifo.
# (GetQueueAttributes on the same queue lets the provider validate itself at provisioning.)
data "aws_iam_policy_document" "api_task" {
  statement {
    sid       = "PublishToAlertsFifo"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    resources = [var.alerts_fifo.arn]
  }

  statement {
    sid       = "EncryptForAlertsFifo"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role" "api_task" {
  name_prefix        = "${var.name}-keep-api-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "api_task" {
  name   = "alerts-fifo"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.api_task.json
}

resource "aws_iam_role" "ui_task" {
  name_prefix        = "${var.name}-keep-ui-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = var.tags
}

# ---- ECS ------------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-keep"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name}/keep-api"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "ui" {
  name              = "/ecs/${var.name}/keep-ui"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

locals {
  api_environment = merge(
    {
      PORT                     = tostring(local.api_port)
      KEEP_API_URL             = local.keep_api_url
      AUTH_TYPE                = "DB"
      KEEP_DEFAULT_USERNAME    = "keep"
      SECRET_MANAGER_TYPE      = "DB"
      PROVISION_RESOURCES      = "true"
      KEEP_PROVIDERS           = jsonencode(local.keep_providers)
      KEEP_WORKFLOWS_DIRECTORY = local.workflows_dir
      REDIS                    = var.redis == null ? "false" : "true"
      REDIS_HOST               = var.redis == null ? "" : var.redis.host
      REDIS_PORT               = var.redis == null ? "" : tostring(var.redis.port)
      PUSHER_DISABLED          = "true"
      POSTHOG_DISABLED         = "true"
      SENTRY_DISABLED          = "true"
      KEEP_METRICS             = "true"
      PROMETHEUS_MULTIPROC_DIR = "/tmp/prometheus"
      LOG_FORMAT               = "open_telemetry"
      LOG_LEVEL                = "INFO"
      AWS_REGION               = data.aws_region.current.region
      AWS_DEFAULT_REGION       = data.aws_region.current.region
    },
    var.keep_extra_environment,
  )

  api_container = {
    name      = "keep-api"
    image     = "${aws_ecr_repository.this["api"].repository_url}:${var.keep_image_tag}"
    essential = true

    portMappings = [{ containerPort = local.api_port, protocol = "tcp" }]

    environment = [for k, v in local.api_environment : { name = k, value = v }]

    secrets = [
      { name = "DATABASE_CONNECTION_STRING", valueFrom = "${var.db_secret_arn}:connection_string::" },
      { name = "KEEP_JWT_SECRET", valueFrom = "${local.app_secret_arn}:jwt_secret::" },
      { name = "KEEP_DEFAULT_PASSWORD", valueFrom = "${local.app_secret_arn}:admin_password::" },
      { name = "KEEP_DEFAULT_API_KEYS", valueFrom = "${local.app_secret_arn}:keep_default_api_keys::" },
    ]

    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://localhost:${local.api_port}/healthcheck || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 120
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }

  ui_container = {
    name      = "keep-ui"
    image     = "${aws_ecr_repository.this["ui"].repository_url}:${var.keep_image_tag}"
    essential = true

    portMappings = [{ containerPort = local.ui_port, protocol = "tcp" }]

    environment = [
      { name = "API_URL", value = local.keep_api_url },
      { name = "NEXTAUTH_URL", value = local.keep_ui_url },
      { name = "AUTH_TYPE", value = "DB" },
      { name = "PUSHER_DISABLED", value = "true" },
      { name = "POSTHOG_DISABLED", value = "true" },
    ]

    secrets = [
      { name = "NEXTAUTH_SECRET", valueFrom = "${local.app_secret_arn}:nextauth_secret::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ui.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "ui"
      }
    }
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name}-keep-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.api_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([local.api_container])
  tags                  = var.tags
}

resource "aws_ecs_task_definition" "ui" {
  family                   = "${var.name}-keep-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ui_cpu
  memory                   = var.ui_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.ui_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([local.ui_container])
  tags                  = var.tags
}

# Rolling deploy that never drops below the desired count (minimum 100%),
# with the circuit breaker rolling back a broken image automatically.
resource "aws_ecs_service" "api" {
  name            = "keep-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 180
  enable_execute_command             = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "keep-api"
    container_port   = local.api_port
  }

  # Fargate spreads tasks across the subnets' AZs automatically.
  tags = var.tags

  depends_on = [aws_lb_listener.api]
}

resource "aws_ecs_service" "ui" {
  name            = "keep-ui"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.ui.arn
  desired_count   = var.ui_desired_count
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "keep-ui"
    container_port   = local.ui_port
  }

  tags = var.tags

  depends_on = [aws_lb_listener.ui]
}
