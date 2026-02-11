resource "local_sensitive_file" "kubeconfig" {
  count = var.config_export.enabled ? 1 : 0

  depends_on = [
    talos_cluster_kubeconfig.this
  ]

  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename        = pathexpand(var.config_export.kubeconfig_path)
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  count = var.config_export.enabled ? 1 : 0

  depends_on = [
    talos_cluster_kubeconfig.this
  ]

  content         = data.talos_client_configuration.this.talos_config
  filename        = pathexpand(var.config_export.talosconfig_path)
  file_permission = "0600"
}
