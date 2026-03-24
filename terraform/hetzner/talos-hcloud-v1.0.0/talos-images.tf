# talos-images.tf - Talos schematic + Hetzner snapshot via imager provider
#
# The imager provider creates the Talos snapshot on Hetzner (via a temp rescue
# server) and returns its numeric ID directly. This bypasses the 63-character
# Hetzner label value limit — schematic IDs are 64-char SHA256 hashes and
# must never be stored as label values.

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.talos.extensions
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos.version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "hcloud"
}

resource "imager_image" "talos" {
  image_url    = data.talos_image_factory_urls.this.urls.disk_image
  architecture = "x86"
  labels = {
    talos_version = var.talos.version
    cluster       = var.cluster_name
    # schematic_id is intentionally omitted — it is 64 chars and exceeds
    # Hetzner's 63-character label value limit.
  }

  lifecycle {
    ignore_changes = [labels]
  }
}
