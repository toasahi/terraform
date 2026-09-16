output "function_name" {
  description = "Dispatcher function name."
  value       = module.function.function_name
}

output "security_group_id" {
  description = "Dispatcher security group ID."
  value       = aws_security_group.this.id
}
