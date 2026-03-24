# random.tf - Unique hex suffix for node naming

resource "random_id" "this" {
  for_each    = merge(var.worker_nodes, var.controlplane_nodes)
  byte_length = 8
  keepers = {
    node = each.key
  }
}
