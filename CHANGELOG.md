# Changelog

All notable changes to AWS-CoreStack-Blueprint are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Planned
- GitHub Actions CI/CD workflows (terraform-plan, terraform-apply, terraform-destroy)
- Prod environment root module
- Architecture Decision Records (ADRs) in docs/architecture/adr/
- Disaster recovery and scaling runbooks

---

## [0.3.0] — Monitoring module

### Added
- `modules/monitoring` — full LGTM stack via Helm on EKS
  - Loki (SimpleScalable mode, S3 backend, Grafana Alloy replacing deprecated Promtail)
  - Mimir (mimir-distributed single-binary, S3 backend, long-term metrics)
  - Tempo (S3 backend, OTLP + Jaeger receivers)
  - kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
  - Prometheus remote-writes to Mimir; local retention 4h only
- gp3 StorageClass created explicitly (replaces EKS default gp2)
- All four LGTM data sources provisioned in Grafana at deploy time
- Tempo → Loki trace-to-log correlation wired via `tracesToLogsV2`
- PrometheusRule custom alerts: node CPU/memory/disk, pod crash-loop, PVC usage, Loki/Mimir health
- Grafana dashboard ConfigMaps with sidecar hot-reload (no Grafana restart required)
- `dashboards/` directory with placeholder JSON and sourcing instructions

---

## [0.2.0] — Application layer modules

### Added
- `modules/alb` — Application Load Balancer with full observability
  - HTTP → HTTPS redirect (301), TLS 1.2/1.3 only (ELBSecurityPolicy-TLS13-1-2-2021-06)
  - `drop_invalid_header_fields = true` (HTTP request smuggling prevention)
  - `deregistration_delay = 30` (aligned with Kubernetes pod termination)
  - `least_outstanding_requests` routing algorithm
  - S3 access log delivery with regional ELB service account bucket policy
  - CloudWatch alarms: 5xx rate (metric math), p99 response time, unhealthy hosts, no healthy hosts
  - WAF WebACL association (optional, guarded by variable)
  - `create_dns_records` guard for environments without Route53
- `modules/rds` — Multi-AZ PostgreSQL with production-grade configuration
  - gp3 storage, storage autoscaling, KMS encryption
  - Parameter group: SSL enforcement, slow query logging, lock wait logging, connection timeouts
  - Master password via `random_password` + Secrets Manager (never in state)
  - Enhanced monitoring (60s interval) + Performance Insights (31-day retention)
  - CloudWatch alarms: CPU, free storage, connection count, read latency, replication lag
  - SNS topic for alarm notifications with optional email subscription
  - `final_snapshot_identifier` uses static name (no `timestamp()` drift)
- `modules/eks` — EKS cluster with production-grade node configuration
  - EKS Access Entries API (replaces deprecated aws-auth ConfigMap)
  - Launch template with IMDSv2-only, encrypted gp3 EBS, detailed monitoring
  - `instance_type` removed from launch template (avoids AWS API conflict with node group `instance_types`)
  - vpc-cni + kube-proxy installed before node group joins (pod networking fix)
  - EBS CSI driver with IRSA + KMS grant (encrypted PVCs work on first apply)
  - OIDC provider created and URL exported for Phase 3 security re-apply
  - CloudWatch log group managed explicitly (90-day retention, KMS encryption)
  - Cluster Autoscaler discovery tags on node group

---

## [0.1.0] — Foundation modules

### Added
- `modules/networking` — three-tier VPC across 2 AZs
  - Public / private / database subnets with AZ-aware CIDR layout
  - One NAT Gateway per AZ (single_nat_gateway variable for dev cost savings)
  - NACLs for all three tiers (database NACL locked to PostgreSQL from private CIDR only)
  - VPC Flow Logs → CloudWatch (30-day retention, scoped IAM policy)
  - Kubernetes subnet discovery tags (kubernetes.io/role/elb, karpenter.sh/discovery)
  - `private_route_table_ids` output for S3 VPC endpoint attachment
- `modules/security` — IAM, KMS, security groups, IRSA
  - KMS key with explicit key policy (EKS, CloudWatch Logs as allowed principals)
  - Security groups: ALB, EKS nodes, EKS control plane, RDS (least-privilege rules)
  - IAM roles: EKS cluster, EKS nodes, with AWS-managed policy attachments
  - IRSA roles: AWS LBC, Cluster Autoscaler, Loki, Mimir, Tempo, External Secrets Operator
  - S3 Gateway VPC endpoint (eliminates NAT Gateway charges for S3 traffic)
  - Two-phase apply pattern documented (oidc_provider variable)
- `modules/s3` — object storage for state, app, and observability backends
  - `for_each` over observability buckets (Loki, Mimir, Tempo) — single source of truth
  - Per-component lifecycle rules matching each tool's access pattern
  - `bucket_key_enabled = true` (reduces KMS API calls by ~99% for high-write buckets)
  - Dedicated access logging bucket (SSE-S3, avoids KMS circular dependency)
  - Bucket policies: deny non-VPC access, allow only scoped IRSA roles (two-phase)
  - Terraform state bucket: versioning, `DenyStateDelete` policy, DynamoDB lock table
- `environments/dev` — root module wiring all seven child modules
  - Two-phase apply order documented in main.tf with exact commands
  - `locals.cluster_name` computed once, shared across security and eks modules
  - `default_tags` on AWS provider (every resource tagged without module boilerplate)
  - OIDC provider URL as variable (explicit dependency, no `-target` workarounds)
  - Sensitive outputs: cluster CA, grafana password via `TF_VAR_` env var pattern
