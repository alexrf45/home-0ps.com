output "kubeconfig" {
  value     = module.hetzner.kubeconfig
  sensitive = true
}

output "lb_ipv4" {
  value       = module.hetzner.lb_ipv4
  description = "Hetzner Load Balancer IPv4 — point application DNS here"
}

output "cluster_endpoint" {
  value       = module.hetzner.cluster_endpoint
  description = "Kubernetes API endpoint"
}

output "post_deployment_instructions" {
  value       = module.hetzner.post_deployment_instructions
  description = "Post-deployment instructions"
}
