# servers.tf - Hetzner Cloud servers for control plane and workers

# Pre-allocate stable public IPs for control plane nodes so the cluster
# endpoint is known before server creation (used in machine configs).
resource "hcloud_primary_ip" "controlplane" {
  for_each      = var.controlplane_nodes
  name          = "${var.cluster_name}-${each.key}-ip"
  type          = "ipv4"
  assignee_type = "server"
  location      = var.hcloud.location
  auto_delete   = false
  labels = {
    cluster = var.cluster_name
    role    = "controlplane"
  }
}

resource "hcloud_server" "controlplane" {
  for_each    = var.controlplane_nodes
  name        = "${var.env}-${var.cluster_name}-cp-${random_id.this[each.key].hex}"
  server_type = each.value.server_type
  image       = imager_image.talos.id
  location    = var.hcloud.location

  firewall_ids = [hcloud_firewall.this.id]
  ssh_keys     = [] # Talos does not use SSH

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.controlplane[each.key].id
    ipv6_enabled = false
  }

  labels = {
    env     = var.env
    cluster = var.cluster_name
    role    = "controlplane"
  }

  lifecycle {
    ignore_changes = [image]
  }
}

resource "hcloud_server_network" "controlplane" {
  for_each  = var.controlplane_nodes
  server_id = hcloud_server.controlplane[each.key].id
  subnet_id = hcloud_network_subnet.this.id
  ip        = each.value.private_ip
}

resource "hcloud_server" "worker" {
  for_each    = var.worker_nodes
  name        = "${var.env}-${var.cluster_name}-node-${random_id.this[each.key].hex}"
  server_type = each.value.server_type
  image       = imager_image.talos.id
  location    = var.hcloud.location

  firewall_ids = [hcloud_firewall.this.id]
  ssh_keys     = []

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  labels = {
    env     = var.env
    cluster = var.cluster_name
    role    = "worker"
  }

  lifecycle {
    ignore_changes = [image]
  }
}

resource "hcloud_server_network" "worker" {
  for_each  = var.worker_nodes
  server_id = hcloud_server.worker[each.key].id
  subnet_id = hcloud_network_subnet.this.id
}
