variable "op_vault_id" {
  description = "UUID of the 1Password vault for infrastructure secrets"
  type        = string
}

variable "op_service_account_token" {
  description = "1Password service account token"
  type        = string
  sensitive   = true
}

variable "env" {
  description = "Environment label used in resource names"
  type        = string
}

variable "talos" {
  description = "Talos cluster configuration"
  type = object({
    version     = string
    k8s_version = string
    extensions  = optional(list(string), [])
  })
}

variable "bootstrap_cluster" {
  description = "Bootstrap the cluster on first apply. Set to false after initial deployment."
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Cluster name (alphanumeric, >= 4 chars)"
  type        = string
}

variable "hcloud" {
  description = "Hetzner Cloud datacenter configuration"
  type = object({
    location     = optional(string, "hil")
    network_zone = optional(string, "us-west")
  })
  default = {}
}

variable "controlplane_nodes" {
  description = "Control plane node configurations"
  type = map(object({
    server_type = optional(string, "cpx21")
    private_ip  = string
  }))
}

variable "worker_nodes" {
  description = "Worker node configurations"
  type = map(object({
    server_type = optional(string, "cpx31")
  }))
  default = {}
}

variable "cilium_config" {
  description = "Cilium CNI bootstrap configuration"
  type = object({
    namespace           = optional(string, "networking")
    kube_version        = string
    cilium_version      = string
    hubble_enabled      = optional(bool, false)
    hubble_ui_enabled   = optional(bool, false)
    relay_enabled       = optional(bool, false)
    relay_pods_rollout  = optional(bool, false)
    gateway_api_enabled = optional(bool, true)
  })
}

variable "flux_config" {
  description = "Flux GitOps bootstrap configuration (git source managed by flux CLI in Phase 2)"
  type = object({
    enabled           = bool
    sops_secret_name  = string
    sops_age_key_name = string
    sops_age_op_title = string
  })
  sensitive = true
}

