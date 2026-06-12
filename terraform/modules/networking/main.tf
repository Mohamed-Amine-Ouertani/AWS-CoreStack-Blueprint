################################################################################
# Locals
# Subnet CIDR layout with a /16 VPC (default 10.0.0.0/16):
#   Public:   10.0.1.0/24, 10.0.2.0/24   (offset  1–9)
#   Private:  10.0.11.0/24, 10.0.12.0/24 (offset 11–19)
#   Database: 10.0.21.0/24, 10.0.22.0/24 (offset 21–29)
# Gaps between tiers intentional — room to add a third AZ without renumbering.
################################################################################

locals {
  az_count = length(var.availability_zones)

  # Short AZ suffix for readable resource names (e.g. eu-central-1a → 1a)
  az_short = [for az in var.availability_zones : substr(az, length(az) - 2, 2)]
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "main" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  enable_network_address_usage_metrics = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-vpc"
  })
}

################################################################################
# Internet Gateway
################################################################################

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-igw"
  })
}

################################################################################
# Subnets
################################################################################

# Public — ALB and NAT Gateways only. No application workloads.
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-public-${local.az_short[count.index]}"
    Tier = "public"
    # Required for AWS Load Balancer Controller to discover subnets for internet-facing ALBs
    "kubernetes.io/role/elb" = "1"
  })
}

# Private — EKS worker nodes and application pods. Egress via NAT.
resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 11)
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-private-${local.az_short[count.index]}"
    Tier = "private"
    # Required for AWS Load Balancer Controller to discover subnets for internal ALBs
    "kubernetes.io/role/internal-elb" = "1"
    # Karpenter node discovery — must match the cluster name passed to Karpenter
    "karpenter.sh/discovery" = "${var.project}-${var.env}"
    # EKS cluster subnet ownership tag
    "kubernetes.io/cluster/${var.project}-${var.env}" = "shared"
  })
}

# Database — RDS Multi-AZ. No route to the internet. Accessible only from private SGs.
resource "aws_subnet" "database" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 21)
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-db-${local.az_short[count.index]}"
    Tier = "database"
  })
}

################################################################################
# Elastic IPs and NAT Gateways
#
# One NAT GW per AZ — if AZ-A's NAT fails, AZ-B traffic continues unaffected.
# Single-NAT mode (var.single_nat_gateway = true) saves ~$32/month in dev
# by sharing one NAT across all AZs at the cost of cross-AZ resilience.
################################################################################

resource "aws_eip" "nat" {
  count  = var.single_nat_gateway ? 1 : local.az_count
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-eip-nat-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = var.single_nat_gateway ? 1 : local.az_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-nat-${local.az_short[count.index]}"
  })

  depends_on = [aws_internet_gateway.main]
}

################################################################################
# Route Tables
################################################################################

# Public — shared across all AZs, routes to IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rt-public"
    Tier = "public"
  })
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private — one per AZ so each AZ routes via its local NAT GW.
# In single_nat_gateway mode all AZs share rt[0]'s NAT — accepted tradeoff for dev.
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rt-private-${local.az_short[count.index]}"
    # CRITICAL: security module's data source filters private route tables by this tag
    # to attach the S3 Gateway VPC endpoint. Do not remove or rename.
    Tier = "private"
  })
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Database — no internet route. Local VPC traffic only.
resource "aws_route_table" "database" {
  count  = local.az_count
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-rt-db-${local.az_short[count.index]}"
    Tier = "database"
  })
}

resource "aws_route_table_association" "database" {
  count          = local.az_count
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database[count.index].id
}

################################################################################
# Network ACLs
#
# NACLs are stateless — rules apply to both directions independently.
# Security Groups handle per-resource access control; NACLs provide
# subnet-level defense-in-depth and an auditable perimeter.
#
# Rule numbering convention:
#   100-199  Ingress allow rules (ascending priority)
#   200-299  Egress allow rules
#   32766    Default deny (implicit — not added explicitly)
################################################################################

# Public NACL — allows HTTP/HTTPS in, all ephemeral ports back out
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  # Inbound
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  # Ephemeral ports — required for TCP response traffic from the internet
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound — allow all (SGs do the fine-grained filtering)
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-nacl-public"
    Tier = "public"
  })
}

# Private NACL — allows all VPC-internal traffic and NAT-egress returns
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # Inbound from VPC CIDR (ALB health checks, inter-pod traffic)
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }
  # Ephemeral ports for NAT return traffic (internet responses to pods)
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Outbound — allow all (NAT GW and SGs handle filtering)
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-nacl-private"
    Tier = "private"
  })
}

# Database NACL — locked down. Only PostgreSQL from private subnet CIDR allowed.
resource "aws_network_acl" "database" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.database[*].id

  # Inbound: PostgreSQL from private subnets only
  dynamic "ingress" {
    for_each = aws_subnet.private[*].cidr_block
    content {
      rule_no    = 100 + ingress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 5432
      to_port    = 5432
    }
  }
  # Ephemeral ports for TCP responses back to EKS nodes
  dynamic "ingress" {
    for_each = aws_subnet.private[*].cidr_block
    content {
      rule_no    = 110 + ingress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value
      from_port  = 1024
      to_port    = 65535
    }
  }

  # Outbound: only to private subnets (RDS responses)
  dynamic "egress" {
    for_each = aws_subnet.private[*].cidr_block
    content {
      rule_no    = 100 + egress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = egress.value
      from_port  = 1024
      to_port    = 65535
    }
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-nacl-database"
    Tier = "database"
  })
}

################################################################################
# VPC Flow Logs
# Captures all ACCEPT/REJECT decisions for post-incident analysis and
# security audit. Scoped to this VPC only; retention set per environment.
################################################################################

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.project}-${var.env}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = var.tags
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project}-${var.env}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.project}-${var.env}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      # Scoped to this log group — not "*"
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn

  tags = merge(var.tags, {
    Name = "${var.project}-${var.env}-flow-logs"
  })
}
