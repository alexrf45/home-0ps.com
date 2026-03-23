# locals.tf - Derived values for cluster networking and node naming

locals {
  first_cp_key  = keys(var.controlplane_nodes)[0]
  cp_private_ip = var.controlplane_nodes[local.first_cp_key].private_ip

  # Cluster endpoint is the CP's public IP (pre-allocated primary IP)
  cluster_endpoint = hcloud_primary_ip.controlplane[local.first_cp_key].ip_address

  pod_subnet     = "10.42.0.0/16"
  service_subnet = "10.43.0.0/16"

  # Worker node hostnames: key => hostname (used by worker labels)
  worker_node_names = {
    for k, v in var.worker_nodes : k => "${var.env}-${var.cluster_name}-node-${random_id.this[k].hex}"
  }

  # Kubeconfig parsed from the file written by the provisioner
  kubeconfig_parsed     = yamldecode(data.local_sensitive_file.kubeconfig.content)
  kubernetes_host       = local.kubeconfig_parsed.clusters[0].cluster.server
  kubernetes_ca_cert    = base64decode(local.kubeconfig_parsed.clusters[0].cluster["certificate-authority-data"])
  kubernetes_client_cert = base64decode(local.kubeconfig_parsed.users[0].user["client-certificate-data"])
  kubernetes_client_key  = base64decode(local.kubeconfig_parsed.users[0].user["client-key-data"])
}
