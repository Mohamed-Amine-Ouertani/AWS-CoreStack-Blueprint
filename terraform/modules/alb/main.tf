################################################################################
# Locals
################################################################################

locals {
  name_prefix = "${var.project}-${var.env}"
}

################################################################################
# Data sources
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# The ELB service account is a regional AWS-owned account that writes ALB
# access logs to S3. Its account ID varies by region — always look it up
# rather than hardcoding. Frankfurt (eu-central-1) = 054676820928.
data "aws_elb_service_account" "main" {}

################################################################################
# ALB Access Logs — S3 bucket policy
#
# ALB access log delivery uses the regional ELB service account, not the
# aws:SourceAccount / aws:SourceArn condition keys. The bucket policy must
# explicitly allow the ELB service account to PutObject on the prefix.
# Without this policy, access logs fail silently — no error, no logs.
################################################################################

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = var.access_logs_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowELBServiceAccountPut"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.access_logs_bucket_id}/alb/${local.name_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        # For regions that use aws:SourceAccount instead of service account ARN
        Sid    = "AllowLogDelivery"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::${var.access_logs_bucket_id}/alb/${local.name_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid    = "AllowACLCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${var.access_logs_bucket_id}"
      }
    ]
  })
}

################################################################################
# Application Load Balancer
################################################################################

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.env == "prod"
  enable_http2               = true

  # Reject requests with invalid HTTP headers (e.g. headers with spaces in the
  # name). Prevents HTTP request smuggling via malformed header injection.
  # Should always be true for ALBs forwarding to application backends.
  drop_invalid_header_fields = true

  # Idle timeout: how long ALB keeps a connection open with no data transfer.
  # 60s is the default — matches most application server keepalive defaults.
  # Increase to 120s if seeing premature connection resets from long-running
  # API calls or file uploads.
  idle_timeout = 60

  access_logs {
    bucket  = var.access_logs_bucket_id
    prefix  = "alb/${local.name_prefix}"
    enabled = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb"
  })

  depends_on = [aws_s3_bucket_policy.alb_access_logs]
}

################################################################################
# Target Group
#
# target_type = "ip" is required for EKS pod-level routing — the AWS Load
# Balancer Controller registers individual pod IPs (not node IPs) as targets.
# This eliminates the extra hop from node to pod via kube-proxy.
################################################################################

resource "aws_lb_target_group" "main" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # 30s deregistration delay — aligned with Kubernetes pod graceful termination.
  # Default 300s would keep routing traffic to a terminated pod for 5 minutes.
  # If your pods need longer than 30s to drain in-flight requests, increase this
  # value and add a matching terminationGracePeriodSeconds in your Deployment.
  deregistration_delay = 30

  # least_outstanding_requests routes to the target with the fewest active
  # requests, not round-robin. Better for heterogeneous request latency (e.g.
  # one endpoint is slow, another is fast — round-robin would pile on the slow).
  load_balancing_algorithm_type = "least_outstanding_requests"

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-299"
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-tg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Listeners
################################################################################

# HTTP → HTTPS redirect — all port 80 traffic gets a 301 to HTTPS.
# Using 301 (permanent) rather than 302 so browsers cache the redirect
# and skip the HTTP round-trip on subsequent visits.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS 1.3 + TLS 1.2 policy — drops 1.0 and 1.1 (both deprecated by RFC 8996).
  # This policy satisfies PCI DSS 3.2.1 and most compliance frameworks.
  # ELBSecurityPolicy-TLS13-1-2-2021-06 supports both TLS 1.3 and 1.2 ciphers.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  tags = var.tags
}

################################################################################
# ACM Certificate + DNS Validation
################################################################################

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-cert"
  })

  lifecycle {
    # Create the new certificate before destroying the old one — prevents
    # downtime during certificate renewal. ALB listener continues serving
    # the old cert until the new one is validated and attached.
    create_before_destroy = true
  }
}

# Route53 zone lookup — only if create_dns_records = true.
# Guards against plan failure when Route53 is not yet configured.
data "aws_route53_zone" "main" {
  count = var.create_dns_records ? 1 : 0

  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.create_dns_records ? {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn

  # If Route53 DNS validation is not used (create_dns_records = false),
  # this resource waits indefinitely until the cert is validated externally.
  # Validate via your DNS provider then re-apply.
  validation_record_fqdns = var.create_dns_records ? [
    for record in aws_route53_record.cert_validation : record.fqdn
  ] : []
}

# Apex A record — domain root points to the ALB
resource "aws_route53_record" "alb_apex" {
  count = var.create_dns_records ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# Wildcard A record — *.domain.com → ALB.
# Allows subdomain routing (api.domain.com, grafana.domain.com, etc.) to
# resolve to the ALB without creating individual Route53 records per service.
# The ALB routes to the correct target group based on Host header rules.
resource "aws_route53_record" "alb_wildcard" {
  count = var.create_dns_records ? 1 : 0

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

################################################################################
# WAF WebACL Association (optional)
# Attach an existing WAF WebACL to the ALB. The WebACL itself is not created
# here — it is managed separately to allow sharing across multiple ALBs and
# to decouple WAF rule updates from infrastructure applies.
################################################################################

resource "aws_wafv2_web_acl_association" "main" {
  count = var.waf_acl_arn != "" ? 1 : 0

  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_acl_arn
}

################################################################################
# CloudWatch Alarms
################################################################################

resource "aws_sns_topic" "alb_alarms" {
  name = "${local.name_prefix}-alb-alarms"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alb-alarms"
  })
}

resource "aws_sns_topic_subscription" "alb_alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alb_alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions    = [aws_sns_topic.alb_alarms.arn]
  alb_dimensions   = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dimensions    = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.main.arn_suffix
  }
}

# 5xx error rate > 1% over 5 minutes
# Calculated as: 5xx / (2xx + 3xx + 4xx + 5xx). Using a metric math expression
# avoids false positives from low-traffic periods where a single 5xx would
# spike the rate to 100%.
resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name_prefix}-alb-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1   # percent
  alarm_description   = "ALB 5xx error rate > 1% over 5 minutes. Check target group health and application logs."
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "(m5xx / (m2xx + m3xx + m4xx + m5xx)) * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "m5xx"
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimensions
    }
  }

  metric_query {
    id = "m2xx"
    metric {
      metric_name = "HTTPCode_Target_2XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimensions
    }
  }

  metric_query {
    id = "m3xx"
    metric {
      metric_name = "HTTPCode_Target_3XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimensions
    }
  }

  metric_query {
    id = "m4xx"
    metric {
      metric_name = "HTTPCode_Target_4XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimensions
    }
  }

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

# Target response time p99 > 2s
resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${local.name_prefix}-alb-response-time-p99"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 2   # seconds
  alarm_description   = "ALB p99 response time > 2s. Check for slow queries, pod resource limits, or HPA scaling lag."
  treat_missing_data  = "notBreaching"

  dimensions = local.tg_dimensions

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

# Unhealthy host count > 0 in target group
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "ALB target group has unhealthy hosts. Pods are failing health checks — check pod logs and readiness probe configuration."
  treat_missing_data  = "notBreaching"

  dimensions = local.tg_dimensions

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}

# Healthy host count drops to 0 — full outage
resource "aws_cloudwatch_metric_alarm" "alb_no_healthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-no-healthy-hosts"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = 0
  alarm_description   = "CRITICAL: ALB has no healthy targets. All pods are failing health checks — service is down."
  treat_missing_data  = "breaching"   # Missing = assume down, not up

  dimensions = local.tg_dimensions

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = var.tags
}
