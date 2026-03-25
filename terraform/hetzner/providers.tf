provider "hcloud" {
  token = data.onepassword_item.hcloud_token.credential
}

provider "imager" {
  token = data.onepassword_item.hcloud_token.credential
}

provider "talos" {}

provider "onepassword" {
  service_account_token = var.op_service_account_token
}

provider "kubernetes" {
  host                   = module.hetzner.kubernetes_host
  client_certificate     = module.hetzner.kubernetes_client_certificate
  client_key             = module.hetzner.kubernetes_client_key
  cluster_ca_certificate = module.hetzner.kubernetes_cluster_ca_certificate
}

provider "helm" {}

data "onepassword_item" "hcloud_token" {
  vault = var.op_vault_id
  title = "hcloud_token"
}
