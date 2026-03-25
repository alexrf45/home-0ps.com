module "hetzner" {
  source = "./talos-hcloud-v1.0.0"

  env          = var.env
  cluster_name = var.cluster_name
  talos        = var.talos
  hcloud = {
    token        = data.onepassword_item.hcloud_token.credential
    location     = var.hcloud.location
    network_zone = var.hcloud.network_zone
  }
  controlplane_nodes = var.controlplane_nodes
  worker_nodes       = var.worker_nodes
  op_vault_id        = var.op_vault_id
  bootstrap_cluster  = var.bootstrap_cluster
}

# Write kubeconfig to a local file so kubectl/flux provisioners can use it
resource "local_sensitive_file" "kubeconfig" {
  depends_on = [module.hetzner]
  content    = module.hetzner.kubeconfig
  filename   = "${path.module}/.kubeconfig"
}

# SOPS Age key from 1Password — created before Flux bootstrap so Flux can decrypt secrets
data "onepassword_item" "sops_age_key" {
  depends_on = [module.hetzner]
  vault      = var.op_vault_id
  title      = var.flux_config.sops_age_op_title
}

resource "kubernetes_secret" "sops_age" {
  count = var.flux_config.enabled ? 1 : 0
  depends_on = [
    module.hetzner,
    data.onepassword_item.sops_age_key,
  ]
  metadata {
    name      = var.flux_config.sops_secret_name
    namespace = "flux-system"
  }
  data = {
    "${var.flux_config.sops_age_key_name}" = data.onepassword_item.sops_age_key.note_value
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

# Hetzner API token secret — used by hcloud-cloud-controller-manager and hcloud-csi
resource "kubernetes_secret" "hcloud_token" {
  depends_on = [module.hetzner]
  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }
  data = {
    token   = data.onepassword_item.hcloud_token.credential
    network = var.cluster_name
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      metadata[0].labels,
    ]
  }
}

# Pre-install Flux CRDs and controllers and verify DNS health.
# This is Phase 1's final gate — Phase 2 (flux bootstrap git) runs only after this passes.
resource "null_resource" "flux_pre_install" {
  depends_on = [null_resource.cilium_installed]

  triggers = {
    server_id = module.hetzner.cluster_endpoint
  }

  provisioner "local-exec" {
    environment = {
      KUBECONFIG = "${path.module}/.kubeconfig"
    }
    command = <<-EOT
      flux install --kubeconfig="$KUBECONFIG"
      kubectl wait --for=condition=Established --timeout=60s \
        crd/kustomizations.kustomize.toolkit.fluxcd.io \
        --kubeconfig="$KUBECONFIG"
      echo "Verifying cluster DNS can reach external hosts..."
      RETRIES=0
      until kubectl exec -n kube-system \
        "$(kubectl get pod -n kube-system -l k8s-app=kube-dns \
           -o jsonpath='{.items[0].metadata.name}' --kubeconfig="$KUBECONFIG")" \
        --kubeconfig="$KUBECONFIG" -- \
        nslookup github.com 2>/dev/null | grep -q "Address:"; do
        RETRIES=$((RETRIES+1))
        if [ "$RETRIES" -ge 18 ]; then
          echo "DNS not operational after 3 minutes, aborting"
          exit 1
        fi
        echo "DNS not ready yet (attempt $RETRIES/18), retrying in 10s..."
        sleep 10
      done
      echo "DNS verified OK"
    EOT
  }
}

