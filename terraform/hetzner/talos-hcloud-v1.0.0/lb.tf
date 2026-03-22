# lb.tf - Hetzner Load Balancer for HTTP/HTTPS ingress

resource "hcloud_load_balancer" "this" {
  name               = var.cluster_name
  load_balancer_type = "lb11"
  location           = var.hcloud.location
  labels = {
    cluster = var.cluster_name
    env     = var.env
  }
}

resource "hcloud_load_balancer_network" "this" {
  load_balancer_id = hcloud_load_balancer.this.id
  subnet_id        = hcloud_network_subnet.this.id
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
}

# Target all worker nodes
resource "hcloud_load_balancer_target" "workers" {
  for_each         = hcloud_server.worker
  type             = "server"
  load_balancer_id = hcloud_load_balancer.this.id
  server_id        = each.value.id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.this]
}

# Also target control plane nodes (single CP acts as worker too)
resource "hcloud_load_balancer_target" "controlplane" {
  for_each         = hcloud_server.controlplane
  type             = "server"
  load_balancer_id = hcloud_load_balancer.this.id
  server_id        = each.value.id
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.this]
}
