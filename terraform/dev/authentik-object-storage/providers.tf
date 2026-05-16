provider "onepassword" {
  account = "Fontaine_Shield"
}

# Cloudflare R2 management token — used by the module to create the bucket,
# set the lifecycle rule, and mint the bucket-scoped data-plane API token.
# Stored in 1Password under "cf-r2-obj-storage-api-token".
data "onepassword_item" "cf_r2_tf_token" {
  vault = var.op_vault_id
  title = "cf-r2-obj-storage-api-token"
}

provider "cloudflare" {
  api_token = data.onepassword_item.cf_r2_tf_token.credential
}

# Declared because the object-storage module's required_providers includes
# aws. With backend = "r2" no AWS resources are created, so the empty
# provider config is harmless — terraform plan/apply will not touch AWS.
provider "aws" {}
