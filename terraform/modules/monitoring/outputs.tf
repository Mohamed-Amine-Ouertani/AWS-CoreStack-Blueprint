output "grafana_service_name" {
  description = "Grafana Kubernetes service name. Use with kubectl port-forward for local access: kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
  value       = "kube-prometheus-stack-grafana"
}

output "loki_gateway_url" {
  description = "Loki gateway URL within the cluster. Used by Alloy and Grafana datasource config."
  value       = "http://loki-gateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local"
}

output "mimir_url" {
  description = "Mimir URL within the cluster. Used by Prometheus remote_write and Grafana datasource config."
  value       = "http://mimir-nginx.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local/prometheus"
}

output "tempo_url" {
  description = "Tempo URL within the cluster. Used by Alloy OTLP exporter and Grafana datasource config."
  value       = "http://tempo.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:3100"
}

output "alloy_otlp_grpc_endpoint" {
  description = "Alloy OTLP gRPC endpoint for application trace instrumentation. Applications send traces here."
  value       = "alloy.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:4317"
}

output "monitoring_namespace" {
  description = "Kubernetes namespace where all monitoring components are deployed."
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

output "prometheus_rule_name" {
  description = "PrometheusRule resource name for custom alert rules."
  value       = "${var.project}-${var.env}-alerts"
}
