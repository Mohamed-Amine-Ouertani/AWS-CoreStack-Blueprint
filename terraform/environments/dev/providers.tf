################################################################################
# Terraform version and provider requirements
################################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

################################################################################
# AWS Provider
################################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

################################################################################
# Helm Provider — authenticates to EKS via short-lived token
#
# Uses aws_eks_cluster_auth to exchange the current caller's IAM identity for a
# Kubernetes bearer token. Tokens are valid for 15 minutes — sufficient for any
# single Terraform apply. The token is never stored in state.
#
# This provider is only active once the EKS cluster exists. Terraform resolves
# the dependency graph automatically because cluster_endpoint and
# cluster_ca_certificate reference module.eks outputs.
################################################################################

data "aws_eks_cluster_auth" "main" {
  name = module.eks.cluster_name
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}

################################################################################
# Kubernetes Provider — same authentication as Helm
################################################################################

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.main.token
}
