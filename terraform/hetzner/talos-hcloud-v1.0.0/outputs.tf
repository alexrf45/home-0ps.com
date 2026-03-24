# outputs.tf - Module outputs for talos-hcloud v1.0.0

output "talos_config" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "kubernetes_host" {
  value     = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  sensitive = true
}

output "kubernetes_client_certificate" {
  value     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  sensitive = true
}

output "kubernetes_client_key" {
  value     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  sensitive = true
}

output "kubernetes_cluster_ca_certificate" {
  value     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
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
    Cluster "${var.cluster_name}" Deployment Complete! (talos-hcloud v1.0.0)
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
