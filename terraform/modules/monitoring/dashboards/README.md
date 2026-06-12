# Grafana Dashboards

These JSON files are loaded into Grafana via ConfigMaps at apply time.
They are sourced from the Grafana community dashboard library and committed
to the repo so applies are hermetic — no runtime downloads required.

## Sourcing dashboards

```bash
# EKS cluster overview — Grafana ID 17119
curl -s "https://grafana.com/api/dashboards/17119/revisions/latest/download" \
  | jq '.' > eks-cluster.json

# RDS metrics — Grafana ID 13993  
curl -s "https://grafana.com/api/dashboards/13993/revisions/latest/download" \
  | jq '.' > rds-metrics.json

# AWS overview (EC2, ALB, EKS) — Grafana ID 139
curl -s "https://grafana.com/api/dashboards/139/revisions/latest/download" \
  | jq '.' > aws-overview.json
```

Run this script once after cloning, then commit the JSON files.
The Terraform `file()` call will fail at plan time if these files are missing.

## Updating dashboards

Re-run the curl commands above to pull the latest revision, review the diff,
then commit. Dashboard updates are independent of infrastructure changes.
