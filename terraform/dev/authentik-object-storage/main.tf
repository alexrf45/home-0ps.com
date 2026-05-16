module "authentik_backup" {
  source = "../../modules/object-storage"

  env         = var.env
  app         = "authentik"
  backend     = "r2"
  op_vault_id = var.op_vault_id

  cloudflare_account_id  = var.cloudflare_account_id
  r2_permission_group_id = var.r2_permission_group_id
  location_hint          = var.location_hint
  lifecycle_days         = var.lifecycle_days
  token_expiry_days      = var.token_expiry_days
}
