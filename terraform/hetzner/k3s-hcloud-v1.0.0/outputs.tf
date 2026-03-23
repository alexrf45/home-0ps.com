# outputs.tf - Module outputs for k3s-hcloud v1.0.0

output "kubeconfig" {
  value     = data.local_sensitive_file.kubeconfig.content
  sensitive = true
}

output "kubernetes_host" {
  value     = local.kubernetes_host
  sensitive = true
}

output "kubernetes_client_certificate" {
  value     = local.kubernetes_client_cert
  sensitive = true
}

output "kubernetes_client_key" {
  value     = local.kubernetes_client_key
  sensitive = true
}

output "kubernetes_cluster_ca_certificate" {
  value     = local.kubernetes_ca_cert
  sensitive = true
}

output "lb_ipv4" {
  value       = hcloud_load_balancer.this.ipv4
  description = "Hetzner Load Balancer public IPv4 — point DNS here"
}

output "cluster_endpoint" {
  value       = "https://${local.cluster_endpoint}:6443"
  description = "Kubernetes API endpoint (control plane public IP)"
}

output "worker_node_names" {
  value       = local.worker_node_names
  description = "Map of worker node keys to their assigned hostnames"
}

output "post_deployment_instructions" {
  value = <<-EOT

    ============================================================
    Cluster "${var.cluster_name}" Deployment Complete! (k3s-hcloud v1.0.0)
    ============================================================

    Load Balancer IPv4: ${hcloud_load_balancer.this.ipv4}
    Cluster Endpoint:   https://${local.cluster_endpoint}:6443

    Next steps:
      1. Point wallabag DNS → LB IPv4 (${hcloud_load_balancer.this.ipv4})
      2. kubectl get nodes
      3. flux get kustomizations

    ============================================================
  EOT
  description = "Post-deployment instructions"
}
