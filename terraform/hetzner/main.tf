module "hetzner" {
  source = "./k3s-hcloud-v1.0.0"

  env          = var.env
  cluster_name = var.cluster_name
  k3s          = var.k3s
  hcloud = {
    token        = data.onepassword_item.hcloud_token.credential
    location     = "ash"
    network_zone = "us-east"
  }
  controlplane_nodes = var.controlplane_nodes
  worker_nodes       = var.worker_nodes
  op_vault_id        = var.op_vault_id
}

# Namespaces required before Flux bootstrap
resource "kubernetes_namespace" "flux_system" {
  depends_on = [module.hetzner, null_resource.cilium_installed]
  metadata {
    name = "flux-system"
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations, metadata[0].labels]
  }
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
    kubernetes_namespace.flux_system,
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

resource "flux_bootstrap_git" "this" {
  count = var.flux_config.enabled ? 1 : 0
  depends_on = [
    module.hetzner,
    null_resource.cilium_installed,
    kubernetes_secret.sops_age,
    kubernetes_secret.hcloud_token,
  ]

  cluster_domain     = var.flux_config.cluster_domain
  path               = var.flux_config.cluster_path
  embedded_manifests = true
}
