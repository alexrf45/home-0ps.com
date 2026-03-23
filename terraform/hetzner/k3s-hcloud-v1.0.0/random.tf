# random.tf - Unique hex suffix for node naming + k3s join token

resource "random_id" "this" {
  for_each    = merge(var.worker_nodes, var.controlplane_nodes)
  byte_length = 8
  keepers = {
    node = each.key
  }
}

resource "random_password" "k3s_token" {
  length  = 64
  special = false
}
