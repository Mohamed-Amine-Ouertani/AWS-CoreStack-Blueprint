# AWS-CoreStack-Blueprint

> **Production-grade, multi-tier AWS infrastructure** provisioned with modular Terraform across two Availability Zones, deployed via GitHub Actions CI/CD, and fully observable through the LGTM stack (Loki · Grafana · Tempo · Mimir).

This project is **Layer 1 of a four-project Platform Engineering portfolio**. The EKS cluster and networking foundation provisioned here are consumed directly by [Project B — Kubernetes/Platform Engineering](#).

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Design Decisions](#design-decisions)
- [Infrastructure Components](#infrastructure-components)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)
- [CI/CD Pipeline](#cicd-pipeline)
- [Observability Stack](#observability-stack)
- [Cost Estimation](#cost-estimation)
- [Roadmap](#roadmap)

---

## Architecture Overview

```
                         ┌─────────────────────────────────────┐
                         │          AWS Region (eu-central-1)  │
                         │                                     │
                         │  ┌──────────────────────────────┐   │
                         │  │            VPC               │   │
                         │  │   10.0.0.0/16                │   │
          Internet ──────┼──┤                              │   │
                         │  │  ┌─── AZ-1a ──┐ ┌─AZ-1b─┐    │   │
                         │  │  │ Public 10.0│ │ Public│    │   │
                         │  │  │  .1.0/24   │ │ .2.0/24│   │   │
                         │  │  │  [ALB]     │ │ [ALB]  │   │   │
                         │  │  │            │ │        │   │   │
                         │  │  │ Priv 10.0  │ │ Priv   │   │   │
                         │  │  │  .11.0/24  │ │ .12.0  │   │   │
                         │  │  │ [EKS Nodes]│ │[EKS]   │   │   │
                         │  │  │            │ │        │   │   │
                         │  │  │ DB 10.0    │ │ DB     │   │   │
                         │  │  │  .21.0/24  │ │.22.0   │   │   │
                         │  │  │  [RDS]     │ │[RDS SB]│   │   │
                         │  │  └────────────┘ └────────┘   │   │
                         │  └──────────────────────────────┘   │
                         │                                     │
                         │  [S3 State Backend] [IAM Roles]     │
                         │  [SSM Parameter Store] [CloudWatch] │
                         └─────────────────────────────────────┘
```

**Three-tier network layout per AZ:**
- **Public subnets** — ALB, NAT Gateways only. No application workloads.
- **Private subnets** — EKS worker nodes, application pods. Egress via NAT.
- **Database subnets** — RDS Multi-AZ. No direct internet path. Accessible only from private subnet SGs.

---

## Design Decisions

> These are the architectural choices that shaped this project, and the reasons behind them. Tradeoffs are documented explicitly — the goal is not to justify every decision, but to show the reasoning process.

### Why modular Terraform over a monolithic root module?

A single root module works for small projects but creates three concrete problems at scale: blast radius (one change can affect all resources), reusability (copy-pasting modules across environments), and team collaboration (lock conflicts on the state file). Splitting by concern — `networking`, `security`, `eks`, `rds`, `s3`, `alb`, `monitoring` — means each module has a defined input/output contract and can be versioned independently.

**Tradeoff accepted:** More inter-module dependency management overhead. Outputs from `networking` must be passed explicitly into `eks`, `rds`, and `alb`. This is intentional — implicit shared state is harder to reason about than explicit wiring.

### Why two Availability Zones and not three?

Three AZs provides better fault tolerance (N-1 capacity at 67% vs 50%) and is the production standard. Two AZs was chosen here for cost control during portfolio demonstration — each AZ adds NAT Gateway ($0.045/hr + data transfer), additional EKS nodes, and an RDS standby instance. The networking module is parameterised (`var.availability_zones`) so switching to three AZs requires a single variable change and `terraform apply`.

### Why EKS over ECS Fargate?

ECS Fargate is operationally simpler — no node management, no cluster upgrades, no kubectl. For a portfolio targeting **Platform Engineering roles**, EKS is the deliberate choice: it demonstrates Kubernetes API familiarity, Helm chart management, node group configuration, and IRSA (IAM Roles for Service Accounts). These are required skills in every Platform Engineer JD reviewed. ECS competence is implied; EKS competence must be demonstrated.

### Why LGTM (Loki + Grafana + Tempo + Mimir) over the ELK stack?

| Dimension | LGTM | ELK |
|---|---|---|
| Resource usage | Lower (Loki indexes labels, not content) | Higher (Elasticsearch is memory-intensive) |
| Cost at scale | Cheaper (object storage for logs) | Expensive (Elasticsearch cluster sizing) |
| German market signal | Growing fast in DACH region | Mature, established, saturating |
| Integration with Grafana | Native | Plugin-based |
| Operational complexity | Moderate | High (Elasticsearch tuning) |

Loki's label-based indexing means logs cost significantly less to store and query than full-text indexed Elasticsearch, which matters for multi-environment deployments. The LGTM stack is also the default observability choice in Grafana Cloud — relevant for German companies standardising on Grafana Enterprise.

### Why GitHub Actions over Jenkins?

Jenkins is what most Tunisian engineering programs teach. GitHub Actions is what German tech companies are migrating to. The CI/CD layer in this project uses GitHub Actions to demonstrate familiarity with the modern default. A Jenkins pipeline for the same workflow is documented in [`docs/runbooks/jenkins-equivalent.md`](docs/runbooks/jenkins-equivalent.md) to show the translation.

---

## Infrastructure Components

| Module | Resources | Purpose |
|---|---|---|
| `networking` | VPC, subnets (6), IGW, NAT GW (2), route tables | Network foundation, AZ isolation |
| `security` | Security groups, NACLs, IAM roles, IRSA policies | Least-privilege access control |
| `eks` | EKS cluster, managed node groups, OIDC provider | Kubernetes control plane + workers |
| `rds` | RDS PostgreSQL Multi-AZ, subnet group, parameter group | Persistent data layer |
| `s3` | Application bucket, Terraform state bucket, lifecycle rules | Object storage + remote state |
| `alb` | ALB, target groups, listeners, ACM certificate | L7 ingress, TLS termination |
| `monitoring` | LGTM stack on EKS, Grafana dashboards, alert rules | Full-stack observability |

---

## Repository Structure

```
AWS-CoreStack-Blueprint/
│
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml       # PR: plan + cost estimate
│       ├── terraform-apply.yml      # Main branch: apply with approval gate
│       └── terraform-destroy.yml    # Manual: full teardown (protected)
│
├── terraform/
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf              # Root module, calls all child modules
│   │   │   ├── variables.tf
│   │   │   ├── outputs.tf
│   │   │   └── terraform.tfvars     # Dev-specific values (not committed)
│   │   └── prod/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       └── terraform.tfvars
│   │
│   └── modules/
│       ├── networking/
│       │   ├── main.tf              # VPC, subnets, IGW, NAT, routes
│       │   ├── variables.tf
│       │   └── outputs.tf           # vpc_id, subnet_ids consumed by other modules
│       ├── security/
│       │   ├── main.tf              # SGs, IAM roles, IRSA, KMS
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── eks/
│       │   ├── main.tf              # EKS cluster, node groups, addons
│       │   ├── variables.tf
│       │   └── outputs.tf           # cluster_endpoint, cluster_ca consumed by Project B
│       ├── rds/
│       │   ├── main.tf              # PostgreSQL Multi-AZ, subnet group
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── s3/
│       │   ├── main.tf              # App bucket + state bucket + policies
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── alb/
│       │   ├── main.tf              # ALB, listeners, target groups, ACM
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── monitoring/
│           ├── main.tf              # LGTM stack via Helm on EKS
│           ├── variables.tf
│           └── outputs.tf
│
├── monitoring/
│   └── lgtm/
│       ├── docker-compose.yml       # Local dev: spin up LGTM without EKS
│       ├── grafana/
│       │   ├── dashboards/
│       │   │   ├── aws-overview.json
│       │   │   ├── eks-cluster.json
│       │   │   └── rds-metrics.json
│       │   └── provisioning/
│       │       ├── dashboards.yml
│       │       └── datasources.yml
│       ├── loki/
│       │   └── loki-config.yml
│       ├── tempo/
│       │   └── tempo-config.yml
│       └── mimir/
│           └── mimir-config.yml
│
├── docs/
│   ├── architecture/
│   │   ├── overview.md
│   │   └── adr/                     # Architecture Decision Records
│   │       ├── 001-multi-az-design.md
│   │       ├── 002-eks-over-ecs.md
│   │       ├── 003-lgtm-over-elk.md
│   │       └── 004-github-actions-over-jenkins.md
│   └── runbooks/
│       ├── disaster-recovery.md
│       ├── scaling-guide.md
│       └── jenkins-equivalent.md
│
├── scripts/
│   ├── bootstrap.sh                 # S3 state backend + DynamoDB lock table
│   └── teardown.sh                  # Ordered destroy (avoids dependency issues)
│
├── .gitignore
├── .terraform-version               # Pinned: 1.7.x
├── CHANGELOG.md
└── README.md
```

---

## Getting Started

### Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | `>= 1.7.0` | Infrastructure provisioning |
| AWS CLI | `>= 2.x` | Authentication |
| kubectl | `>= 1.29` | Cluster interaction (post-deploy) |
| helm | `>= 3.14` | LGTM stack deployment |

### 1. Configure AWS credentials

```bash
aws configure --profile corestack
export AWS_PROFILE=corestack
```

### 2. Bootstrap remote state

Remote state must exist before any `terraform init`. The bootstrap script creates the S3 bucket and DynamoDB lock table:

```bash
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh --env dev --region eu-central-1
```

### 3. Initialise and plan

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan -out=tfplan
```

### 4. Apply

```bash
terraform apply tfplan
```

> **Note:** Full apply takes approximately 15–20 minutes. EKS cluster creation (~10 min) and RDS Multi-AZ provisioning (~8 min) are the longest steps.

### 5. Configure kubectl

```bash
aws eks update-kubeconfig \
  --region eu-central-1 \
  --name $(terraform output -raw eks_cluster_name)
```

---

## CI/CD Pipeline

```
Pull Request                    Main Branch
─────────────                   ───────────
Push to PR branch               Merge to main
       │                               │
       ▼                               ▼
  terraform fmt                  terraform plan
  terraform validate             infracost diff
  terraform plan                 Manual approval gate (GitHub Env)
  infracost comment              terraform apply
  tfsec scan                     Slack notification
  Post plan to PR
```

### Key pipeline decisions

**Plan on PR, apply on merge** — prevents infrastructure changes from landing without peer review. The plan output is posted as a PR comment so reviewers see exactly what will change.

**Infracost on every PR** — cost diff is surfaced before merge. A networking change that accidentally adds a NAT Gateway shows a $32/month increase in the PR, not in the AWS bill.

**`tfsec` security scanning** — static analysis catches misconfigurations (e.g., S3 bucket public access, unencrypted RDS) before they reach the AWS account.

**Manual approval gate on apply** — GitHub Environments with required reviewers. The `prod` environment requires two approvals. The `dev` environment requires one.

---

## Observability Stack

The LGTM stack is deployed as Helm releases on the EKS cluster provisioned by this project.

| Signal | Tool | Storage |
|---|---|---|
| Metrics | Mimir | S3 (long-term) |
| Logs | Loki | S3 (long-term) |
| Traces | Tempo | S3 (long-term) |
| Dashboards | Grafana | ConfigMap (GitOps) |

**Pre-built dashboards:**
- AWS infrastructure overview (EC2, EKS, RDS, ALB health)
- EKS cluster metrics (pod count, node utilisation, PVC usage)
- RDS performance (connection count, query latency, replication lag)

**Alert rules cover:**
- Node CPU > 80% for 5 minutes
- Pod crash-looping (restart count > 3 in 10 min)
- RDS free storage < 10 GB
- ALB 5xx rate > 1% over 5 minutes

**Local development:** Run the full LGTM stack locally without EKS:

```bash
cd monitoring/lgtm
docker compose up -d
# Grafana available at http://localhost:3000 (admin/admin)
```

---

## Cost Estimation

> Estimated monthly cost for the `dev` environment in `eu-central-1`.
> Generated with [Infracost](https://www.infracost.io/).

| Resource | Config | Est. Cost/month |
|---|---|---|
| EKS Cluster | Control plane | ~$73 |
| EKS Node Group | 2× t3.medium (On-Demand) | ~$60 |
| RDS PostgreSQL | db.t3.micro, Multi-AZ | ~$45 |
| NAT Gateways | 2× (one per AZ) | ~$65 |
| ALB | 1× with minimal traffic | ~$18 |
| S3 | State + app (minimal data) | ~$2 |
| **Total** | | **~$263/month** |

**Cost optimisation notes:**
- `dev` uses `t3.medium` nodes and `db.t3.micro` RDS. `prod` uses `t3.large` and `db.t3.small`.
- NAT Gateways are the most significant fixed cost. Single-AZ NAT could save ~$32/month but removes HA at the network layer.
- EKS node group uses On-Demand in this config. Spot instances would reduce node cost ~60% but require tolerations and PodDisruptionBudgets.

---

## Roadmap

This project feeds directly into the next three layers of the portfolio:

- **[Project B — Kubernetes/Platform Engineering](#):** Microservices deployed on this EKS cluster, with Helm, HPA, and chaos engineering.
- **[Project C — GitOps + Security](#):** ArgoCD and Kyverno layered on top of this cluster. Vault uses the IAM roles provisioned here.
- **[Project D — Internal Developer Platform](#):** Backstage IDP surfaces this infrastructure in a self-service catalog.

---

## License

MIT — see [LICENSE](LICENSE).