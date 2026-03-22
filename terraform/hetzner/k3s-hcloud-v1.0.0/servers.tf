# servers.tf - Hetzner Cloud servers for control plane and workers

# Pre-allocate stable public IPs for control plane nodes so the cluster
# endpoint is known before server creation (used in TLS SANs).
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
  image       = "ubuntu-24.04"
  location    = var.hcloud.location

  firewall_ids = [hcloud_firewall.this.id]
  ssh_keys     = [hcloud_ssh_key.provisioner.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.controlplane[each.key].id
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/templates/cp-cloud-init.yaml.tpl", {
    k3s_token      = random_password.k3s_token.result
    k3s_channel    = var.k3s.channel
    pod_cidr       = local.pod_subnet
    service_cidr   = local.service_subnet
    cp_public_ip   = hcloud_primary_ip.controlplane[each.key].ip_address
    cp_private_ip  = each.value.private_ip
  })

  labels = {
    env     = var.env
    cluster = var.cluster_name
    role    = "controlplane"
  }

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
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
  image       = "ubuntu-24.04"
  location    = var.hcloud.location

  firewall_ids = [hcloud_firewall.this.id]
  ssh_keys     = [hcloud_ssh_key.provisioner.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  user_data = templatefile("${path.module}/templates/worker-cloud-init.yaml.tpl", {
    k3s_token     = random_password.k3s_token.result
    k3s_channel   = var.k3s.channel
    cp_private_ip = local.cp_private_ip
  })

  labels = {
    env     = var.env
    cluster = var.cluster_name
    role    = "worker"
  }

  lifecycle {
    ignore_changes = [user_data, ssh_keys]
  }
}

resource "hcloud_server_network" "worker" {
  for_each  = var.worker_nodes
  server_id = hcloud_server.worker[each.key].id
  subnet_id = hcloud_network_subnet.this.id
}
