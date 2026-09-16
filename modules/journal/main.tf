# AlertEventJournal: the durable record that lives OUTSIDE Keep.
#   PK  event_id      : one firing occurrence of an alert (fingerprint + firing start)
#   SK  transition_id : one firing/resolved transition of that occurrence
# The Normalize Lambda writes with a Conditional Put, the routing tool flips
# notification_status pending -> delivered with a Conditional Update, and the
# Dispatcher / Reconciler maintain keep_status.
# Streams are enabled from day one so the table can become a global table
# (Osaka replica) without recreation.

locals {
  journal_name = "${var.name_prefix}-alert-event-journal"
  routing_name = "${var.name_prefix}-service-routing"
}

resource "aws_dynamodb_table" "journal" {
  count = var.create ? 1 : 0

  name         = local.journal_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  range_key    = "transition_id"

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "transition_id"
    type = "S"
  }

  attribute {
    name = "fingerprint"
    type = "S"
  }

  attribute {
    name = "received_at"
    type = "S"
  }

  attribute {
    name = "keep_status"
    type = "S"
  }

  attribute {
    name = "notification_status"
    type = "S"
  }

  # Correlation: everything that happened to one alert, in time order.
  global_secondary_index {
    name            = "fingerprint-received_at-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "fingerprint"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "received_at"
      key_type       = "RANGE"
    }
  }

  # Reconciler: keep_status = pending older than N minutes.
  global_secondary_index {
    name            = "keep_status-received_at-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "keep_status"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "received_at"
      key_type       = "RANGE"
    }
  }

  # Reconciler: notification_status = pending (critical) older than N minutes.
  global_secondary_index {
    name            = "notification_status-received_at-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "notification_status"
      key_type       = "HASH"
    }

    key_schema {
      attribute_name = "received_at"
      key_type       = "RANGE"
    }
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  dynamic "replica" {
    for_each = var.replicas
    content {
      region_name            = replica.key
      kms_key_arn            = replica.value.kms_key_arn
      point_in_time_recovery = true
      propagate_tags         = true
    }
  }

  deletion_protection_enabled = true
  tags                        = var.tags
}

# Service -> room routing table. The content is Git-managed (routing_entries in
# tfvars) and materialised into DynamoDB so the routing Lambda can read it at
# runtime. Keep never owns this mapping.
resource "aws_dynamodb_table" "routing" {
  count = var.create ? 1 : 0

  name         = local.routing_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service"

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "service"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  dynamic "replica" {
    for_each = var.replicas
    content {
      region_name            = replica.key
      kms_key_arn            = replica.value.kms_key_arn
      point_in_time_recovery = true
      propagate_tags         = true
    }
  }

  deletion_protection_enabled = true
  tags                        = var.tags
}

resource "aws_dynamodb_table_item" "routing" {
  for_each = var.create ? var.routing_entries : {}

  table_name = aws_dynamodb_table.routing[0].name
  hash_key   = "service"

  item = jsonencode({
    service  = { S = each.key }
    room     = { S = each.value.room }
    mentions = { L = [for m in each.value.mentions : { S = m }] }
  })
}

data "aws_dynamodb_table" "journal" {
  count = var.create ? 0 : 1
  name  = local.journal_name
}

data "aws_dynamodb_table" "routing" {
  count = var.create ? 0 : 1
  name  = local.routing_name
}
