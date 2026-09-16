output "journal_table_name" {
  description = "Name of the AlertEventJournal table."
  value       = var.create ? aws_dynamodb_table.journal[0].name : data.aws_dynamodb_table.journal[0].name
}

output "journal_table_arn" {
  description = "ARN of the AlertEventJournal table in this region."
  value       = var.create ? aws_dynamodb_table.journal[0].arn : data.aws_dynamodb_table.journal[0].arn
}

output "journal_stream_arn" {
  description = "Stream ARN of the AlertEventJournal table."
  value       = var.create ? aws_dynamodb_table.journal[0].stream_arn : data.aws_dynamodb_table.journal[0].stream_arn
}

output "routing_table_name" {
  description = "Name of the service routing table."
  value       = var.create ? aws_dynamodb_table.routing[0].name : data.aws_dynamodb_table.routing[0].name
}

output "routing_table_arn" {
  description = "ARN of the service routing table in this region."
  value       = var.create ? aws_dynamodb_table.routing[0].arn : data.aws_dynamodb_table.routing[0].arn
}
