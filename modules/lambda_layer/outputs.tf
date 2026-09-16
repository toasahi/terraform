output "arn" {
  description = "ARN of the layer version."
  value       = aws_lambda_layer_version.this.arn
}
