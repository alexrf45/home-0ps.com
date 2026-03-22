resource "onepassword_item" "kubeconfig" {
  count      = var.config_export.enabled ? 1 : 0
  vault      = var.op_vault_id
  title      = "${var.cluster_name}-kubeconfig"
  category   = "secure_note"
  note_value = data.local_sensitive_file.kubeconfig.content

  depends_on = [null_resource.k3s_ready]
}
