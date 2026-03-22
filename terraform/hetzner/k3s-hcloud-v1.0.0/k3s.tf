# k3s.tf - SSH provisioner key, wait-for-ready, and kubeconfig retrieval

resource "tls_private_key" "provisioner" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "provisioner" {
  name       = "${var.cluster_name}-provisioner"
  public_key = tls_private_key.provisioner.public_key_openssh
}

# Wait for k3s to be ready on the CP, then write kubeconfig to a local file.
# Both provisioners run within the same terraform apply, so the file is
# available to data.local_sensitive_file.kubeconfig in the same execution.
resource "null_resource" "k3s_ready" {
  depends_on = [
    hcloud_server.controlplane,
    hcloud_server_network.controlplane,
    hcloud_server.worker,
    hcloud_server_network.worker,
  ]

  triggers = {
    server_id = hcloud_server.controlplane[local.first_cp_key].id
  }

  # Wait until k3s is running and all nodes are Ready
  provisioner "remote-exec" {
    connection {
      host        = hcloud_server.controlplane[local.first_cp_key].ipv4_address
      user        = "root"
      private_key = tls_private_key.provisioner.private_key_openssh
      timeout     = "10m"
    }
    inline = [
      "until [ -f /etc/rancher/k3s/k3s.yaml ]; do sleep 5; done",
      "until kubectl get nodes --kubeconfig /etc/rancher/k3s/k3s.yaml 2>/dev/null | grep -qv 'No resources'; do sleep 10; done",
      "kubectl wait --for=condition=Ready nodes --all --kubeconfig /etc/rancher/k3s/k3s.yaml --timeout=10m",
    ]
  }

  # Retrieve kubeconfig with the public IP substituted for 127.0.0.1
  provisioner "local-exec" {
    environment = {
      PRIVATE_KEY = tls_private_key.provisioner.private_key_openssh
      HOST        = hcloud_server.controlplane[local.first_cp_key].ipv4_address
      OUT         = "${path.module}/.kubeconfig"
    }
    command = <<-EOT
      echo "$PRIVATE_KEY" > /tmp/k3s-provisioner.key
      chmod 600 /tmp/k3s-provisioner.key
      ssh -o StrictHostKeyChecking=no \
          -o ConnectTimeout=30 \
          -i /tmp/k3s-provisioner.key \
          root@$HOST \
          "cat /etc/rancher/k3s/k3s.yaml | sed \"s|127.0.0.1|$HOST|g\"" \
          > "$OUT"
      rm -f /tmp/k3s-provisioner.key
    EOT
  }
}

data "local_sensitive_file" "kubeconfig" {
  depends_on = [null_resource.k3s_ready]
  filename   = "${path.module}/.kubeconfig"
}
