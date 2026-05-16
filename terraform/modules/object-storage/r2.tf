# =============================================================================
# Cloudflare R2 backend
#
# The R2 data-plane S3-compatible credentials are derived from a regular
# Cloudflare API token scoped to the bucket:
#   AWS_ACCESS_KEY_ID     = api_token.id
#   AWS_SECRET_ACCESS_KEY = sha256(api_token.value)   (hex digest)
# This is the documented Cloudflare R2 mapping; Barman / boto3 / aws-cli all
# work against the bucket's S3 endpoint with that pair.
#
# The permission group UUID for "Workers R2 Storage Bucket Item Write" is
# passed in via var.r2_permission_group_id rather than discovered at apply
# time — the cloudflare_*_permission_groups_list data sources require token
# permissions (API Tokens: Read) that the lab's narrow management token
# does not carry, and the UUIDs are stable. See README for the one-liner
# to fetch the ID once.
# =============================================================================

resource "cloudflare_r2_bucket" "this" {
  count         = var.backend == "r2" ? 1 : 0
  account_id    = var.cloudflare_account_id
  name          = local.bucket_name
  location      = var.location_hint
  storage_class = var.storage_class
}

resource "cloudflare_r2_bucket_lifecycle" "this" {
  count       = var.backend == "r2" && var.lifecycle_days > 0 ? 1 : 0
  account_id  = var.cloudflare_account_id
  bucket_name = cloudflare_r2_bucket.this[0].name

  rules = [{
    id      = "delete-after-${var.lifecycle_days}d"
    enabled = true
    conditions = {
      prefix = ""
    }
    # Sweep stale objects N days after upload. Set well above Barman's own
    # retention so we never delete a live backup.
    delete_objects_transition = {
      condition = {
        type    = "Age"
        max_age = var.lifecycle_days * 86400
      }
    }
    # Clean up multipart uploads that never completed (Barman or
    # interrupted CLI runs leave these behind).
    abort_multipart_uploads_transition = {
      condition = {
        type    = "Age"
        max_age = 7 * 86400
      }
    }
  }]
}

resource "time_offset" "token_expiry" {
  count       = var.backend == "r2" ? 1 : 0
  offset_days = var.token_expiry_days
}

resource "cloudflare_api_token" "r2_bucket" {
  count = var.backend == "r2" ? 1 : 0
  name  = "${local.bucket_name}-rw"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = var.r2_permission_group_id
    }]
    # Bucket-scoped resource URN. Jurisdiction is "default" for buckets
    # created without an explicit jurisdiction; format is account-id _
    # jurisdiction _ bucket-name (literal underscores).
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${local.bucket_name}" = "*"
    })
  }]

  expires_on = time_offset.token_expiry[0].rfc3339
}

resource "onepassword_item" "r2_creds" {
  count    = var.backend == "r2" ? 1 : 0
  vault    = var.op_vault_id
  title    = local.op_item_title
  category = "login"

  section {
    label = "r2_credentials"

    field {
      label = "AWS_ACCESS_KEY_ID"
      type  = "CONCEALED"
      value = cloudflare_api_token.r2_bucket[0].id
    }
    field {
      label = "AWS_SECRET_ACCESS_KEY"
      type  = "CONCEALED"
      value = sha256(cloudflare_api_token.r2_bucket[0].value)
    }
    field {
      label = "AWS_ENDPOINT_URL"
      type  = "STRING"
      value = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
    }
    field {
      label = "AWS_REGION"
      type  = "STRING"
      value = "auto"
    }
    field {
      label = "BUCKET_NAME"
      type  = "STRING"
      value = cloudflare_r2_bucket.this[0].name
    }
    field {
      label = "EXPIRES_ON"
      type  = "STRING"
      value = time_offset.token_expiry[0].rfc3339
    }
  }
}
