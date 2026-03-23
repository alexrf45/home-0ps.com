# network.tf - Hetzner private network, subnet, and firewall

resource "hcloud_network" "this" {
  name     = var.cluster_name
  ip_range = "10.0.0.0/16"
  labels = {
    cluster = var.cluster_name
    env     = var.env
  }
}

resource "hcloud_network_subnet" "this" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = var.hcloud.network_zone
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_firewall" "this" {
  name = var.cluster_name
  labels = {
    cluster = var.cluster_name
    env     = var.env
  }

  # Kubernetes API
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = ["0.0.0.0/0"]
  }

  # SSH for Terraform provisioner (bootstrap only)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0"]
  }

  # HTTP/HTTPS ingress
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0"]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0"]
  }

  # Cilium health checks (TCP)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "4240"
    source_ips = ["10.0.0.0/16"]
  }

  # Cilium VXLAN overlay
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "8472"
    source_ips = ["10.0.0.0/16"]
  }

  # Cilium WireGuard
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51871"
    source_ips = ["0.0.0.0/0"]
  }
}
