# locals.tf - Derived values for cluster networking and node naming

locals {
  # First control plane key and its pre-allocated public IP
  first_cp_key      = keys(var.controlplane_nodes)[0]
  cluster_endpoint  = hcloud_primary_ip.controlplane[local.first_cp_key].ip_address

  # Pod and service subnets (same as dev cluster)
  pod_subnet     = "10.42.0.0/16"
  service_subnet = "10.43.0.0/16"
  coredns_ip     = "10.43.0.10"

  # Talos image: use snapshot_id if provided, else query Hetzner API via external data source.
  # Returns 0 when no snapshot exists (safe during destroy — servers are deleted by ID, not image).
  talos_image_id = var.talos.snapshot_id != null ? var.talos.snapshot_id : tonumber(data.external.talos_snapshot[0].result.id)

  # Worker node hostnames: key => hostname (used by kubernetes_labels)
  worker_node_names = {
    for k, v in var.worker_nodes : k => "${var.env}-${var.cluster_name}-node-${random_id.this[k].hex}"
  }
}
