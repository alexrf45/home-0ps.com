output "backend" {
  value = module.authentik_backup.backend
}

output "bucket_name" {
  value = module.authentik_backup.bucket_name
}

output "endpoint_url" {
  value = module.authentik_backup.endpoint_url
}

output "region" {
  value = module.authentik_backup.region
}

output "op_item_title" {
  description = "The 1Password item name the cluster's ExternalSecret reads from."
  value       = module.authentik_backup.op_item_title
}

output "token_expires_on" {
  value = module.authentik_backup.token_expires_on
}
