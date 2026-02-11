provider "aws" {

}

provider "talos" {
}

provider "proxmox" {
  endpoint = "https://${var.pve.endpoint}:8006"
  username = "root@pam"
  password = var.pve.password
  insecure = true
  ssh {
    agent = false
  }
}

provider "kubernetes" {
  host                   = module.cluster.kubernetes_host
  client_certificate     = module.cluster.kubernetes_client_certificate
  client_key             = module.cluster.kubernetes_client_key
  cluster_ca_certificate = module.cluster.kubernetes_cluster_ca_certificate
}

provider "flux" {
  kubernetes = {
    host                   = module.cluster.kubernetes_host
    client_certificate     = module.cluster.kubernetes_client_certificate
    client_key             = module.cluster.kubernetes_client_key
    cluster_ca_certificate = module.cluster.kubernetes_cluster_ca_certificate
  }
  git = {
    url = var.flux_config.git_url
    ssh = {
      username    = "git"
      private_key = file(pathexpand(var.flux_config.ssh_private_key_path))
    }
  }
}


