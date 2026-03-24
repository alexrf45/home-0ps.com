variable "env" {
  description = "Operating environment label (used in resource names)"
  type        = string
}

variable "cluster_name" {
  description = "Cluster name (alphanumeric, >= 4 chars)"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9]+$", var.cluster_name)) && length(var.cluster_name) >= 4
    error_message = "Cluster name must contain only alphanumeric characters and be at least 4 characters long."
  }
}

variable "hcloud" {
  description = "Hetzner Cloud configuration"
  type = object({
    token        = string
    location     = optional(string, "hil")
    network_zone = optional(string, "us-west")
  })
  sensitive = true
}

variable "talos" {
  description = "Talos cluster configuration"
  type = object({
    version     = string
    k8s_version = string
    extensions  = optional(list(string), [])
  })
}

variable "controlplane_nodes" {
  description = "Control plane node configurations — odd count required for etcd quorum"
  type = map(object({
    server_type = optional(string, "cpx21")
    private_ip  = string
  }))
  validation {
    condition     = length(var.controlplane_nodes) >= 1 && length(var.controlplane_nodes) % 2 == 1
    error_message = "Control plane requires an odd number of nodes (1, 3, or 5) for etcd quorum."
  }
}

variable "worker_nodes" {
  description = "Worker node configurations — scale independently without touching control plane"
  type = map(object({
    server_type = optional(string, "cpx31")
  }))
  default = {}
}

variable "op_vault_id" {
  description = "UUID of the 1Password vault for infrastructure secrets"
  type        = string
}

variable "config_export" {
  description = "Export kubeconfig and talosconfig to 1Password"
  type = object({
    enabled = optional(bool, true)
  })
  default = {
    enabled = true
  }
}

variable "bootstrap_cluster" {
  description = "Bootstrap the cluster on first apply. Set to false after initial deployment."
  type        = bool
  default     = true
}

variable "worker_labels" {
  description = "Labels to apply to worker nodes after bootstrap"
  type = object({
    enabled = optional(bool, true)
    labels = optional(map(string), {
      "node-role.kubernetes.io/worker" = "true"
      "node"                           = "worker"
    })
  })
  default = {
    enabled = true
    labels = {
      "node-role.kubernetes.io/worker" = "true"
      "node"                           = "worker"
    }
  }
}
