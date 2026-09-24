# Keep's state: RDS PostgreSQL (Multi-AZ) and ElastiCache Redis (Multi-AZ, ARQ
# job queue). Both live in the isolated data subnets and only accept traffic
# from security groups that the keep_service module attaches.
# All Keep state that matters (providers, workflows, secrets via
# SECRET_MANAGER_TYPE=DB, alerts) lives in PostgreSQL, so a cross-region read
# replica carries everything needed for DR. Redis is a re-creatable job queue.

data "aws_region" "current" {}

locals {
  is_primary = var.db_role == "primary"
  db_name    = "keep"
  db_user    = "keep"
  db_port    = 5432
}

# ---- Security groups ----------------------------------------------------------

resource "aws_security_group" "db" {
  name        = "${var.name}-keep-db"
  description = "Keep PostgreSQL"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-keep-db" })
}

resource "aws_security_group" "redis" {
  count = var.create_redis ? 1 : 0

  name        = "${var.name}-keep-redis"
  description = "Keep Redis (ARQ)"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-keep-redis" })
}

# ---- RDS ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-keep"
  subnet_ids = var.data_subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-keep-pg16-"
  family      = "postgres16"
  description = "Keep PostgreSQL 16 (TLS enforced)"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "random_password" "db" {
  count = local.is_primary ? 1 : 0

  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "primary" {
  count = local.is_primary ? 1 : 0

  identifier     = "${var.name}-keep"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = local.db_name
  username = local.db_user
  password = random_password.db[0].result
  port     = local.db_port

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = var.db_backup_retention_days
  backup_window              = "17:00-18:00" # 02:00-03:00 JST
  maintenance_window         = "sun:18:00-sun:19:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false
  copy_tags_to_snapshot      = true
  deletion_protection        = var.db_deletion_protection
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-keep-final"

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = var.tags
}

# Cross-region read replica (Phase 3). Promotion is a manual/Step Functions
# step: `aws rds promote-read-replica`. The replica is encrypted with this
# region's key.
resource "aws_db_instance" "replica" {
  count = local.is_primary ? 0 : 1

  identifier          = "${var.name}-keep"
  replicate_source_db = var.db_replicate_source_arn
  instance_class      = var.db_instance_class
  port                = local.db_port

  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period    = var.db_backup_retention_days
  auto_minor_version_upgrade = true
  apply_immediately          = false
  copy_tags_to_snapshot      = true
  deletion_protection        = var.db_deletion_protection
  # PostgreSQL read replicas cannot be snapshotted; the primary keeps the backups.
  skip_final_snapshot = true

  performance_insights_enabled    = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = var.tags
}

locals {
  db_endpoint = local.is_primary ? aws_db_instance.primary[0].address : aws_db_instance.replica[0].address
  db_arn      = local.is_primary ? aws_db_instance.primary[0].arn : aws_db_instance.replica[0].arn
  db_id       = local.is_primary ? aws_db_instance.primary[0].identifier : aws_db_instance.replica[0].identifier
}

# ---- Connection secret ------------------------------------------------------------

data "aws_secretsmanager_secret_version" "source_password" {
  count = local.is_primary ? 0 : 1

  secret_id = var.db_password_source_secret_arn
}

locals {
  db_password = local.is_primary ? random_password.db[0].result : jsondecode(data.aws_secretsmanager_secret_version.source_password[0].secret_string).password

  connection_string = "postgresql+psycopg2://${local.db_user}:${urlencode(local.db_password)}@${local.db_endpoint}:${local.db_port}/${local.db_name}?sslmode=require"
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name}/keep/database"
  description = "Keep PostgreSQL connection (injected into ECS as DATABASE_CONNECTION_STRING)"
  kms_key_id  = var.kms_key_arn

  dynamic "replica" {
    for_each = toset(var.secret_replica_regions)
    content {
      region = replica.value
    }
  }

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    connection_string = local.connection_string
    username          = local.db_user
    password          = local.db_password
    host              = local.db_endpoint
    port              = local.db_port
    dbname            = local.db_name
  })
}

# ---- Redis ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  count = var.create_redis ? 1 : 0

  name       = "${var.name}-keep"
  subnet_ids = var.data_subnet_ids
  tags       = var.tags
}

# Transit encryption is off: Keep's Redis client configuration exposes
# host/port/credentials but no TLS switch (ADR-0006). Access is limited to the
# Keep task security group inside the isolated data subnets.
resource "aws_elasticache_replication_group" "this" {
  count = var.create_redis ? 1 : 0

  replication_group_id = "${var.name}-keep"
  description          = "Keep ARQ job queue"
  engine               = "redis"
  engine_version       = var.redis_engine_version
  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = "default.redis7"

  num_cache_clusters         = 2
  multi_az_enabled           = true
  automatic_failover_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.this[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = false

  snapshot_retention_limit   = 1
  snapshot_window            = "17:00-18:00"
  maintenance_window         = "sun:19:00-sun:20:00"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = var.tags
}
