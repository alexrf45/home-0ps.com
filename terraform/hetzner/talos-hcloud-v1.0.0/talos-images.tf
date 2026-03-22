# talos-images.tf - Talos schematic + hcloud snapshot image builder

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

# ── Image builder (only runs when snapshot_id is not provided) ──────────────

# Ephemeral key pair — generated per apply, used only for the rescue server
# provisioner, never stored outside Terraform state.
resource "tls_private_key" "builder" {
  count     = var.talos.snapshot_id == null ? 1 : 0
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "builder" {
  count      = var.talos.snapshot_id == null ? 1 : 0
  name       = "${var.cluster_name}-talos-builder"
  public_key = tls_private_key.builder[0].public_key_openssh
}

# Temporary rescue server — boots debian, flashes Talos raw image to /dev/sda
resource "hcloud_server" "builder" {
  count       = var.talos.snapshot_id == null ? 1 : 0
  name        = "${var.cluster_name}-talos-builder"
  server_type = "cpx11"
  image       = "debian-12"
  location    = var.hcloud.location
  rescue      = "linux64"
  ssh_keys    = [hcloud_ssh_key.builder[0].id]
  labels = {
    role    = "talos-image-builder"
    cluster = var.cluster_name
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = self.ipv4_address
      user        = "root"
      private_key = tls_private_key.builder[0].private_key_openssh
    }
    inline = [
      "apt-get install -y -q xz-utils",
      "wget -q -O - '${data.talos_image_factory_urls.this.urls.disk_image}' | xz -d | dd of=/dev/sda bs=4M status=none",
      "sync",
    ]
  }
}

# Power off server, create labeled snapshot, print ID for tfvars update
resource "null_resource" "talos_snapshot" {
  count = var.talos.snapshot_id == null ? 1 : 0
  depends_on = [hcloud_server.builder]

  triggers = {
    server_id    = hcloud_server.builder[0].id
    talos_version = var.talos.version
    schematic_id = talos_image_factory_schematic.this.id
  }

  provisioner "local-exec" {
    environment = {
      HCLOUD_TOKEN  = var.hcloud.token
      SERVER_ID     = hcloud_server.builder[0].id
      TALOS_VERSION = var.talos.version
      SCHEMATIC_ID  = talos_image_factory_schematic.this.id
      CLUSTER_NAME  = var.cluster_name
    }
    command = <<-EOF
      set -e
      curl -sX POST \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        "https://api.hetzner.cloud/v1/servers/$SERVER_ID/actions/poweroff" > /dev/null
      sleep 45
      SNAP_ID=$(curl -s \
        -X POST \
        -H "Authorization: Bearer $HCLOUD_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"description\":\"talos-$TALOS_VERSION\",\"type\":\"snapshot\",\"labels\":{\"managed-by\":\"terraform\",\"talos_version\":\"$TALOS_VERSION\",\"schematic_id\":\"$SCHEMATIC_ID\",\"cluster\":\"$CLUSTER_NAME\"}}" \
        "https://api.hetzner.cloud/v1/servers/$SERVER_ID/actions/create_image" | jq -r '.image.id')
      echo "Talos snapshot created: $SNAP_ID"
      echo "Set talos.snapshot_id = $SNAP_ID in terraform.tfvars to skip builder on next apply."
      echo $SNAP_ID > ${path.module}/.talos_snapshot_id
    EOF
  }
}

# Query Hetzner for the snapshot ID. Uses --data-urlencode so the label
# selector is properly encoded. Returns {"id":"0"} when no snapshot exists
# (e.g. during destroy) so the data source never errors out.
data "external" "talos_snapshot" {
  count      = var.talos.snapshot_id == null ? 1 : 0
  depends_on = [null_resource.talos_snapshot]
  program = ["bash", "-c", <<-EOT
    curl -sf https://api.hetzner.cloud/v1/images \
      -H "Authorization: Bearer ${var.hcloud.token}" \
      -G \
      --data-urlencode "type=snapshot" \
      --data-urlencode "label_selector=managed-by=terraform,talos_version=${var.talos.version},cluster=${var.cluster_name}" \
    | jq -c '{id: (.images // [] | sort_by(.created) | last // {} | .id // 0 | tostring)}' \
    || echo '{"id":"0"}'
  EOT
  ]
}
