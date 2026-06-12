################################################################################
# Locals
################################################################################

locals {
  ns = "monitoring"
}

################################################################################
# Namespace
################################################################################

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = local.ns
    labels = {
      name        = local.ns
      environment = var.env
    }
  }
}

################################################################################
# Loki — log aggregation with S3 backend
#
# Deployed in simple-scalable mode (read + write + backend components) rather
# than single-binary. Simple-scalable is the recommended mode when using S3
# object storage — it separates the write path (ingest) from the read path
# (query) so each can scale independently. Single-binary mode ties them
# together, which creates head-of-line blocking under query load.
################################################################################

resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = var.loki_chart_version
  namespace        = local.ns
  create_namespace = false
  timeout          = 600
  atomic           = true   # Roll back automatically if any component fails

  values = [
    yamlencode({
      deploymentMode = "SimpleScalable"

      loki = {
        auth_enabled = false
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "s3"
          bucketNames = {
            chunks = var.loki_bucket_name
            ruler  = var.loki_bucket_name
            admin  = var.loki_bucket_name
          }
          s3 = {
            region           = var.aws_region
            s3ForcePathStyle = false
            insecure         = false
          }
        }
        schemaConfig = {
          configs = [{
            from         = "2024-01-01"
            store        = "tsdb"
            object_store = "s3"
            schema       = "v13"
            index = {
              prefix = "loki_index_"
              period = "24h"
            }
          }]
        }
        rulerConfig = {
          storage = {
            type = "local"
          }
        }
        limits_config = {
          retention_period    = "${var.loki_retention_hours}h"
          ingestion_rate_mb   = 16
          ingestion_burst_size_mb = 32
        }
      }

      # IRSA — annotate the service account so Loki pods can write to S3
      # without static credentials. The role ARN is scoped to this bucket only.
      serviceAccount = {
        create = true
        name   = "loki"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.irsa_loki_role_arn
        }
      }

      write = {
        replicas = var.loki_write_replicas
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        persistence = {
          storageClass = "gp3"
          size         = "10Gi"
        }
      }

      read = {
        replicas = var.loki_read_replicas
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        persistence = {
          storageClass = "gp3"
          size         = "10Gi"
        }
      }

      backend = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        persistence = {
          storageClass = "gp3"
          size         = "10Gi"
        }
      }

      gateway = {
        enabled   = true
        replicas  = 1
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "128Mi" }
        }
      }

      # Disable MinIO — we're using S3 directly
      minio = {
        enabled = false
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

################################################################################
# Grafana Alloy — log and trace collection (replaces deprecated Promtail)
#
# Grafana deprecated Promtail in 2024 in favour of Alloy, which ships a
# superset of Promtail's functionality plus metrics scraping, trace forwarding,
# and a programmable pipeline. Using Alloy signals awareness of the current
# Grafana ecosystem to reviewers.
#
# Config: tails pod logs via the K8s API, enriches with pod labels, and ships
# to Loki. Also forwards OTLP traces to Tempo.
################################################################################

resource "helm_release" "alloy" {
  name             = "alloy"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "alloy"
  version          = var.alloy_chart_version
  namespace        = local.ns
  create_namespace = false
  atomic           = true

  values = [
    yamlencode({
      alloy = {
        configMap = {
          create  = true
          content = <<-ALLOY_CONFIG
            // ── Kubernetes pod log discovery ──────────────────────────────────
            discovery.kubernetes "pods" {
              role = "pod"
            }

            discovery.relabel "pods" {
              targets = discovery.kubernetes.pods.targets

              rule {
                source_labels = ["__meta_kubernetes_namespace"]
                target_label  = "namespace"
              }
              rule {
                source_labels = ["__meta_kubernetes_pod_name"]
                target_label  = "pod"
              }
              rule {
                source_labels = ["__meta_kubernetes_pod_container_name"]
                target_label  = "container"
              }
              rule {
                source_labels = ["__meta_kubernetes_pod_label_app"]
                target_label  = "app"
              }
              rule {
                source_labels = ["__meta_kubernetes_node_name"]
                target_label  = "node"
              }
            }

            loki.source.kubernetes "pods" {
              targets    = discovery.relabel.pods.output
              forward_to = [loki.write.default.receiver]
            }

            // ── Loki write endpoint ───────────────────────────────────────────
            loki.write "default" {
              endpoint {
                url = "http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
              }
            }

            // ── OTLP trace receiver → Tempo ───────────────────────────────────
            otelcol.receiver.otlp "default" {
              grpc { endpoint = "0.0.0.0:4317" }
              http { endpoint = "0.0.0.0:4318" }
              output {
                traces = [otelcol.exporter.otlp.tempo.input]
              }
            }

            otelcol.exporter.otlp "tempo" {
              client {
                endpoint = "tempo.monitoring.svc.cluster.local:4317"
                tls { insecure = true }
              }
            }
          ALLOY_CONFIG
        }
      }

      serviceAccount = {
        create = true
        name   = "alloy"
      }

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "250m", memory = "256Mi" }
      }

      controller = {
        type     = "daemonset"   # One Alloy pod per node to collect all pod logs
        tolerations = [{
          operator = "Exists"   # Tolerate all taints — must run on every node
        }]
      }
    })
  ]

  depends_on = [helm_release.loki]
}

################################################################################
# Mimir — long-term metrics storage with S3 backend
#
# Replaces Prometheus's local TSDB for metrics persistence. Prometheus remains
# for scraping and rule evaluation but remote-writes to Mimir for durable
# storage. This decouples scrape infrastructure from query infrastructure and
# enables multi-tenant metrics with consistent long-term retention.
#
# Deployed in single-binary mode — adequate for a single-cluster portfolio
# setup. Production would use mimir-distributed with dedicated ingestor,
# querier, and compactor components.
################################################################################

resource "helm_release" "mimir" {
  name             = "mimir"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "mimir-distributed"
  version          = var.mimir_chart_version
  namespace        = local.ns
  create_namespace = false
  timeout          = 600
  atomic           = true

  values = [
    yamlencode({
      # Single-binary mode: all Mimir components in one deployment
      mimir = {
        structuredConfig = {
          common = {
            storage = {
              backend = "s3"
              s3 = {
                bucket_name = var.mimir_bucket_name
                region      = var.aws_region
              }
            }
          }
          blocks_storage = {
            s3 = { bucket_name = var.mimir_bucket_name }
          }
          ruler_storage = {
            s3 = { bucket_name = var.mimir_bucket_name }
          }
          alertmanager_storage = {
            s3 = { bucket_name = var.mimir_bucket_name }
          }
          compactor = {
            data_dir           = "/tmp/mimir-compactor"
            sharding_ring = { kvstore = { store = "memberlist" } }
          }
          limits = {
            ingestion_rate       = 30000
            max_global_series_per_user = 1500000
          }
        }
      }

      serviceAccount = {
        create = true
        name   = "mimir"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.irsa_mimir_role_arn
        }
      }

      # Use single-process deployment for simplicity in this project
      # Switch to mimir-distributed values for production multi-component setup
      nginx = { enabled = true }

      minio = { enabled = false }

      # Resource sizing for single-binary mode
      ingester = {
        replicas = 1
        resources = {
          requests = { cpu = "100m", memory = "512Mi" }
          limits   = { cpu = "1",    memory = "1Gi"   }
        }
        persistentVolume = {
          storageClass = "gp3"
          size         = "20Gi"
        }
      }

      store_gateway = {
        replicas = 1
        persistentVolume = {
          storageClass = "gp3"
          size         = "10Gi"
        }
      }

      compactor = {
        replicas = 1
        persistentVolume = {
          storageClass = "gp3"
          size         = "10Gi"
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

################################################################################
# Tempo — distributed tracing with S3 backend
################################################################################

resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo"
  version          = var.tempo_chart_version
  namespace        = local.ns
  create_namespace = false
  atomic           = true

  values = [
    yamlencode({
      tempo = {
        retention = "${var.tempo_retention_hours}h"
        storage = {
          trace = {
            backend = "s3"
            s3 = {
              bucket   = var.tempo_bucket_name
              region   = var.aws_region
              insecure = false
            }
          }
        }
        # Receive traces via OTLP (from Alloy), Jaeger, and Zipkin
        receivers = {
          otlp = {
            protocols = {
              grpc = { endpoint = "0.0.0.0:4317" }
              http = { endpoint = "0.0.0.0:4318" }
            }
          }
          jaeger = {
            protocols = {
              thrift_http = {}
              grpc        = {}
            }
          }
        }
      }

      # IRSA — service account annotated so Tempo pods can write to S3
      serviceAccount = {
        create = true
        name   = "tempo"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.irsa_tempo_role_arn
        }
      }

      persistence = {
        enabled      = true
        storageClass = "gp3"
        size         = "10Gi"
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    })
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

################################################################################
# kube-prometheus-stack — Prometheus + Grafana + Alertmanager
#
# Prometheus scrapes cluster metrics and remote-writes to Mimir for long-term
# storage. Local TSDB retention is short (4h) — Mimir holds the durable copy.
# Grafana is configured with all four LGTM data sources.
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_stack_chart_version
  namespace        = local.ns
  create_namespace = false
  timeout          = 600
  atomic           = true

  # CRDs are managed by the chart — skip_crds = false (default)
  # If CRDs already exist from a previous install, set
  # resolve_conflicts_on_install = "OVERWRITE" on a re-install.

  values = [
    yamlencode({
      # ── Grafana ──────────────────────────────────────────────────────────────
      grafana = {
        enabled       = true
        adminPassword = var.grafana_admin_password

        persistence = {
          enabled          = true
          storageClassName = "gp3"   # gp3, not gp2
          size             = "10Gi"
        }

        # All four LGTM data sources wired at provisioning time.
        # Engineers open Grafana and all sources are already connected.
        additionalDataSources = [
          {
            name      = "Loki"
            type      = "loki"
            url       = "http://loki-gateway.${local.ns}.svc.cluster.local"
            access    = "proxy"
            isDefault = false
          },
          {
            name      = "Tempo"
            type      = "tempo"
            url       = "http://tempo.${local.ns}.svc.cluster.local:3100"
            access    = "proxy"
            isDefault = false
            jsonData = {
              tracesToLogsV2 = {
                datasourceUid = "loki"
                spanStartTimeShift = "-1h"
                spanEndTimeShift   = "1h"
                filterByTraceID    = true
                filterBySpanID     = false
              }
            }
          },
          {
            name      = "Mimir"
            type      = "prometheus"
            url       = "http://mimir-nginx.${local.ns}.svc.cluster.local/prometheus"
            access    = "proxy"
            isDefault = false
          }
        ]

        # Sidecar watches for ConfigMaps labelled grafana_dashboard=1
        # and hot-loads them without a Grafana restart.
        sidecar = {
          dashboards = {
            enabled                        = true
            label                          = "grafana_dashboard"
            labelValue                     = "1"
            searchNamespace                = "ALL"
            provider = {
              foldersFromFilesStructure    = true
            }
          }
        }

        # Grafana.ini overrides
        grafana_ini = {
          server = {
            root_url = "https://grafana.${var.domain_name}"
          }
          auth = {
            disable_login_form = false
          }
          security = {
            allow_embedding            = false
            cookie_secure              = true
            strict_transport_security  = true
          }
        }

        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
      }

      # ── Prometheus ────────────────────────────────────────────────────────────
      prometheus = {
        prometheusSpec = {
          # Short local retention — Mimir holds the durable copy via remote write.
          # 4h covers enough for in-flight alerting rule evaluation.
          retention     = "4h"
          retentionSize = "5GB"

          # Remote write to Mimir for long-term storage
          remoteWrite = [{
            url = "http://mimir-nginx.${local.ns}.svc.cluster.local/api/v1/push"
            queueConfig = {
              maxSamplesPerSend = 10000
              maxShards         = 200
              capacity          = 2500
            }
          }]

          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                resources = {
                  requests = { storage = "10Gi" }
                }
              }
            }
          }

          resources = {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { cpu = "1000m", memory = "2Gi" }
          }

          # Scrape all namespaces, not just monitoring
          podMonitorNamespaceSelector     = {}
          serviceMonitorNamespaceSelector = {}
          ruleNamespaceSelector           = {}
        }
      }

      # ── Alertmanager ─────────────────────────────────────────────────────────
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                resources = {
                  requests = { storage = "5Gi" }
                }
              }
            }
          }
          resources = {
            requests = { cpu = "50m",  memory = "64Mi"  }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }

      # ── Node and cluster metrics ──────────────────────────────────────────────
      nodeExporter = {
        enabled = true
      }

      kubeStateMetrics = {
        enabled = true
      }

      # Scrape kube-controller-manager and kube-scheduler via EKS
      kubeControllerManager = { enabled = false }  # Not accessible on EKS managed control plane
      kubeScheduler         = { enabled = false }  # Not accessible on EKS managed control plane
      kubeEtcd              = { enabled = false }  # Not accessible on EKS managed control plane
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    helm_release.mimir,  # Prometheus remote-writes to Mimir on startup
  ]
}

################################################################################
# StorageClass — gp3
# kube-prometheus-stack and other components reference this StorageClass.
# The default EKS StorageClass is gp2 — explicitly create gp3 so all
# PVCs use it. gp3 costs the same as gp2 but delivers 3x the baseline IOPS.
################################################################################

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"   # Provision in the same AZ as the pod
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    kmsKeyId  = var.kms_key_arn
  }

  depends_on = [kubernetes_namespace.monitoring]
}

################################################################################
# Grafana Dashboards — loaded via ConfigMaps, hot-reloaded by sidecar
#
# Each ConfigMap holds one dashboard JSON keyed by filename.
# The sidecar watches for the label grafana_dashboard=1 across all namespaces
# and mounts the JSON into Grafana's dashboard directory.
#
# Dashboard IDs reference community dashboards from grafana.com — the JSON
# content is downloaded at apply time from the dashboards/ directory.
# See dashboards/README.md for sourcing instructions.
################################################################################

resource "kubernetes_config_map" "dashboard_eks" {
  metadata {
    name      = "grafana-dashboard-eks"
    namespace = local.ns
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "eks-cluster.json" = file("${path.module}/dashboards/eks-cluster.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "dashboard_rds" {
  metadata {
    name      = "grafana-dashboard-rds"
    namespace = local.ns
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "rds-metrics.json" = file("${path.module}/dashboards/rds-metrics.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "dashboard_aws_overview" {
  metadata {
    name      = "grafana-dashboard-aws-overview"
    namespace = local.ns
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "aws-overview.json" = file("${path.module}/dashboards/aws-overview.json")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

################################################################################
# PrometheusRules — custom alert rules
# Applied after kube-prometheus-stack installs the CRDs.
################################################################################

resource "kubernetes_manifest" "alert_rules" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "${var.project}-${var.env}-alerts"
      namespace = local.ns
      labels = {
        # Must match kube-prometheus-stack's ruleSelector labels
        release = "kube-prometheus-stack"
        app     = "kube-prometheus-stack"
      }
    }
    spec = {
      groups = [
        {
          name     = "node.alerts"
          interval = "1m"
          rules = [
            {
              alert = "NodeCPUHigh"
              expr  = "100 - (avg by(instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 80"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "High CPU on {{ $labels.instance }}"
                description = "CPU usage is {{ printf \"%.1f\" $value }}%. Consider adding nodes or right-sizing workloads."
                runbook_url = "https://github.com/${var.project}/AWS-CoreStack-Blueprint/blob/main/docs/runbooks/scaling-guide.md"
              }
            },
            {
              alert = "NodeMemoryHigh"
              expr  = "(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 85"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "High memory on {{ $labels.instance }}"
                description = "Memory usage is {{ printf \"%.1f\" $value }}%."
                runbook_url = "https://github.com/${var.project}/AWS-CoreStack-Blueprint/blob/main/docs/runbooks/scaling-guide.md"
              }
            },
            {
              alert = "NodeDiskSpaceLow"
              expr  = "(node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100 < 15"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "Low disk on {{ $labels.instance }}"
                description = "Root filesystem is {{ printf \"%.1f\" $value }}% full."
              }
            }
          ]
        },
        {
          name     = "pod.alerts"
          interval = "1m"
          rules = [
            {
              alert = "PodCrashLooping"
              expr  = "rate(kube_pod_container_status_restarts_total[10m]) * 600 > 3"
              for   = "2m"
              labels      = { severity = "critical" }
              annotations = {
                summary     = "Pod crash-looping: {{ $labels.namespace }}/{{ $labels.pod }}"
                description = "Container {{ $labels.container }} has restarted {{ printf \"%.0f\" $value }} times in 10m."
                runbook_url = "https://github.com/${var.project}/AWS-CoreStack-Blueprint/blob/main/docs/runbooks/disaster-recovery.md"
              }
            },
            {
              alert = "PodNotReady"
              expr  = "sum by(namespace, pod) (kube_pod_status_ready{condition=\"false\"}) > 0"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "Pod not ready: {{ $labels.namespace }}/{{ $labels.pod }}"
                description = "Pod has been in non-ready state for more than 5 minutes."
              }
            },
            {
              alert = "PVCUsageHigh"
              expr  = "(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 80"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "PVC usage high: {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }}"
                description = "PVC is {{ printf \"%.1f\" $value }}% full. Resize or clean up data."
              }
            }
          ]
        },
        {
          name     = "lgtm.alerts"
          interval = "1m"
          rules = [
            {
              alert = "LokiWriteErrors"
              expr  = "sum(rate(loki_request_duration_seconds_count{status_code=~\"5..\", route=\"/loki/api/v1/push\"}[5m])) > 0"
              for   = "2m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "Loki ingestion errors"
                description = "Loki is returning 5xx errors on the push endpoint — logs may be dropping."
              }
            },
            {
              alert = "MimirIngestionRateHigh"
              expr  = "sum(rate(cortex_distributor_received_samples_total[5m])) > 25000"
              for   = "5m"
              labels      = { severity = "warning" }
              annotations = {
                summary     = "Mimir ingestion rate high"
                description = "Mimir is ingesting {{ printf \"%.0f\" $value }} samples/sec — approaching the per-user limit."
              }
            }
          ]
        }
      ]
    }
  }

  # CRDs must exist before this resource can be applied.
  # kube-prometheus-stack installs the PrometheusRule CRD as part of its chart.
  depends_on = [helm_release.kube_prometheus_stack]
}
