################################################################################
# ALB identity — consumed by monitoring module and AWS LBC Helm values
################################################################################

output "alb_arn" {
  description = "ALB ARN. Used in WAF association and CloudWatch alarm dimensions."
  value       = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (short form). Used directly in CloudWatch metric dimensions."
  value       = aws_lb.main.arn_suffix
}

output "alb_dns_name" {
  description = "ALB DNS name. Used as the alias target for Route53 records and as the external-facing URL before custom domain is configured."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "ALB hosted zone ID. Required when creating Route53 alias records in other modules or stacks."
  value       = aws_lb.main.zone_id
}

################################################################################
# Listeners — consumed by AWS LBC IngressClass and Helm chart config
################################################################################

output "https_listener_arn" {
  description = "HTTPS listener ARN. AWS Load Balancer Controller uses this to attach Ingress rules as listener rules."
  value       = aws_lb_listener.https.arn
}

output "http_listener_arn" {
  description = "HTTP listener ARN (redirect to HTTPS). Exported for reference — do not attach application rules here."
  value       = aws_lb_listener.http.arn
}

################################################################################
# Target group
################################################################################

output "target_group_arn" {
  description = "Default target group ARN. Used as the fallback target for the HTTPS listener."
  value       = aws_lb_target_group.main.arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix. Used in CloudWatch alarm dimensions."
  value       = aws_lb_target_group.main.arn_suffix
}

################################################################################
# TLS
################################################################################

output "certificate_arn" {
  description = "ACM certificate ARN. Pass to additional HTTPS listeners or CloudFront distributions."
  value       = aws_acm_certificate.main.arn
}

################################################################################
# DNS (conditional — only populated when create_dns_records = true)
################################################################################

output "apex_fqdn" {
  description = "Apex domain FQDN (e.g. example.com). Empty string when create_dns_records = false."
  value       = var.create_dns_records ? aws_route53_record.alb_apex[0].fqdn : ""
}

output "wildcard_fqdn" {
  description = "Wildcard FQDN (e.g. *.example.com). Empty string when create_dns_records = false."
  value       = var.create_dns_records ? aws_route53_record.alb_wildcard[0].fqdn : ""
}

################################################################################
# Alerting
################################################################################

output "alarm_sns_topic_arn" {
  description = "SNS topic ARN for ALB CloudWatch alarms. Wire additional subscriptions (PagerDuty, Slack) externally after apply."
  value       = aws_sns_topic.alb_alarms.arn
}
