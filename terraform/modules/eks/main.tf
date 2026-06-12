################################################################################
# EKS Cluster
################################################################################

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.eks_cluster_role_arn

  vpc_config {
    # Control plane ENIs are placed in private subnets.
    # Public subnets are listed so ALB controller can discover subnet AZs,
    # but control plane traffic stays private.
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [var.sg_control_plane_id]
    endpoint_private_access = true
    endpoint_public_access  = var.enable_public_endpoint
    public_access_cidrs     = var.enable_public_endpoint ? var.public_access_cidrs : []
  }

  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    # Encrypts K8s Secrets at rest in etcd. Does not encrypt all etcd data —
    # only objects of kind Secret. For full etcd encryption, AWS manages the
    # underlying etcd key separately.
    resources = ["secrets"]
  }

  enabled_cluster_log_types = [
    "api",           # API server audit log — required for security incident response
    "audit",         # K8s RBAC audit trail
    "authenticator", # aws-iam-authenticator logs — IRSA and IAM auth failures appear here
    "controllerManager",
    "scheduler"
  ]

  # Implicit dependency on eks_cluster_role_arn via role_arn attribute handles ordering.
  # Do NOT add depends_on = [var.eks_cluster_role_arn] — Terraform cannot depend_on
  # a string variable and it causes a plan error.

  tags = merge(var.tags, {
    Name = var.cluster_name
  })
}

################################################################################
# CloudWatch Log Group for control plane logs
# EKS auto-creates this group if not managed here, but with infinite retention.
# Explicit management sets a retention policy and applies KMS encryption.
################################################################################

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.control_plane_log_retention_days
  kms_key_id        = var.kms_key_arn

  # Must exist before cluster creation — EKS writes to this group immediately
  # after the cluster API becomes active.
  tags = merge(var.tags, {
    Name = "${var.cluster_name}-control-plane-logs"
  })
}

################################################################################
# OIDC Provider (required for IRSA)
# The thumbprint is derived from the TLS certificate of the EKS OIDC issuer.
# AWS does not rotate this certificate, so the thumbprint is stable.
################################################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

################################################################################
# IRSA: EBS CSI Driver
# The EBS CSI addon is installed below, but without an IRSA-backed service
# account it cannot call ec2:CreateVolume / ec2:AttachVolume. Every PVC that
# requests an EBS-backed StorageClass will hang in Pending without this role.
################################################################################

data "aws_caller_identity" "current" {}

locals {
  oidc_provider = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-irsa-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Grant the EBS CSI role permission to use the KMS key for encrypted volumes
resource "aws_iam_role_policy" "ebs_csi_kms" {
  name = "${var.cluster_name}-ebs-csi-kms"
  role = aws_iam_role.ebs_csi.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kms:CreateGrant",
        "kms:ListGrants",
        "kms:RevokeGrant",
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey"
      ]
      Resource = var.kms_key_arn
    }]
  })
}

################################################################################
# EKS Managed Addons
#
# Ordering matters:
#   vpc-cni   → must be active before nodes join (handles pod networking)
#   kube-proxy → must be active before nodes join (handles service routing)
#   coredns    → requires nodes to be ready (runs as pods)
#   ebs-csi    → requires nodes and IRSA role
#
# resolve_conflicts_on_create = "OVERWRITE" handles the case where AWS
# pre-installs a default version of vpc-cni and kube-proxy — without this,
# Terraform errors on "addon already exists".
################################################################################

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.vpc_cni.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Enable network policy support — required for Project C (Kyverno network policies)
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.kube_proxy.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # CoreDNS runs as pods — needs nodes Ready before it can schedule
  depends_on = [aws_eks_node_group.main]

  tags = var.tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_node_group.main]

  tags = var.tags
}

# Resolve latest addon versions compatible with the cluster's K8s version
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

################################################################################
# Launch Template
# Separating instance config from the node group resource allows rolling
# updates without destroying the node group: bump the LT version, then the
# node group picks it up on next update_config cycle.
#
# NOTE: Do NOT set instance_type here when instance_types is set on the node
# group. AWS rejects the combination. Instance type selection lives exclusively
# in aws_eks_node_group.instance_types.
################################################################################

resource "aws_launch_template" "eks_nodes" {
  name_prefix   = "${var.cluster_name}-nodes-"
  # instance_type is intentionally omitted — set via node group's instance_types
  # to allow multiple instance types (cost optimisation for Spot) without conflict.

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      iops                  = 3000  # gp3 baseline; tune up for high-IOPS workloads
      throughput            = 125   # gp3 baseline in MB/s
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 only — blocks SSRF-based metadata theft
    http_put_response_hop_limit = 2            # 1 = EC2 only, 2 = allows pods on the node
  }

  monitoring {
    enabled = true  # Enables detailed CloudWatch instance metrics (1-min resolution)
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.cluster_name}-node-ebs"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# Managed Node Group
################################################################################

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng-${var.node_group_name}"
  node_role_arn   = var.eks_node_role_arn
  subnet_ids      = var.private_subnet_ids

  # Multiple instance types enable Cluster Autoscaler to find capacity when
  # the primary type is unavailable. For Spot, this is essential — price
  # spikes on one type don't strand the autoscaler.
  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  update_config {
    # 25% max unavailable balances update speed with availability.
    # With 2 nodes this means 1 at a time. With 4 nodes, 1 at a time.
    max_unavailable_percentage = 25
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  labels = {
    role        = var.node_group_name
    environment = var.env
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-node-group"
    # Cluster Autoscaler discovery tags — must match the CA deployment's cluster-name flag
    "k8s.io/cluster-autoscaler/enabled"              = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"  = "owned"
  })

  # vpc-cni must be active before nodes join — otherwise nodes start with the
  # default AWS VNI and pod networking is broken until a manual rollout.
  depends_on = [
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  lifecycle {
    # Cluster Autoscaler adjusts desired_size out-of-band.
    # Ignoring it prevents Terraform from fighting the autoscaler on every apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

################################################################################
# EKS Access Entries (replaces aws-auth ConfigMap management)
#
# Access Entries are the AWS-recommended approach for EKS 1.21+ clusters.
# Unlike direct aws-auth ConfigMap management, Access Entries:
#   - Are managed via the EKS API (not a K8s ConfigMap) — no race condition
#     with cluster availability
#   - Support IAM principal ARN patterns, not just exact role ARNs
#   - Are audited in CloudTrail as EKS API calls, not K8s API calls
#
# The node role entry allows worker nodes to authenticate to the cluster.
# Additional entries (CI/CD role, developer groups) are added here as needed.
################################################################################

resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.eks_node_role_arn
  type          = "EC2_LINUX"

  tags = var.tags
}

# GitHub Actions CI/CD role — if provided, grants read-only cluster access
# for deployment pipelines. Scoped to cluster-viewer, not cluster-admin.
resource "aws_eks_access_entry" "cicd" {
  count = var.cicd_role_arn != "" ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cicd_role_arn
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "cicd" {
  count = var.cicd_role_arn != "" ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.cicd_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cicd]
}
