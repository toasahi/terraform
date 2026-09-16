output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs (ECS, ALB, in-VPC Lambda)."
  value       = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  description = "Data subnet IDs (RDS, ElastiCache)."
  value       = aws_subnet.data[*].id
}

output "availability_zones" {
  description = "Availability Zones used."
  value       = local.azs
}

output "nat_gateway_id" {
  description = "ID of the Regional NAT Gateway."
  value       = aws_nat_gateway.regional.id
}
