output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of public subnets (one per AZ). Used by: ALB module."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of private subnets (one per AZ). Used by: EKS module."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "IDs of database subnets (one per AZ). Used by: RDS module."
  value       = aws_subnet.database[*].id
}

output "private_route_table_ids" {
  description = "IDs of private route tables (one per AZ). Used by: security module to attach the S3 Gateway VPC endpoint."
  value       = aws_route_table.private[*].id
}

output "database_route_table_ids" {
  description = "IDs of database route tables (one per AZ)."
  value       = aws_route_table.database[*].id
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways. Count is 1 if single_nat_gateway=true, else equals AZ count."
  value       = aws_nat_gateway.main[*].id
}

output "nat_public_ips" {
  description = "Elastic IP addresses of NAT Gateways. Add to allowlists for egress traffic."
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "vpc_flow_log_group_name" {
  description = "CloudWatch Log Group name for VPC Flow Logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.name
}

output "availability_zones" {
  description = "AZs this VPC is deployed into. Passed to downstream modules that need AZ-aware placement."
  value       = var.availability_zones
}
