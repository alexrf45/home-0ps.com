output "backend" {
  description = "Which backend was actually provisioned ('r2' or 'aws_s3')."
  value       = var.backend
}

output "bucket_name" {
  description = "Final bucket name (uniform across backends)."
  value       = var.backend == "r2" ? cloudflare_r2_bucket.this[0].name : aws_s3_bucket.this[0].id
}

output "endpoint_url" {
  description = "S3-compatible endpoint URL. Empty string for AWS (boto3/Barman default to the AWS endpoint for the region)."
  value       = var.backend == "r2" ? "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com" : ""
}

output "region" {
  description = "Region to pass to S3 clients. 'auto' for R2; AWS region for S3."
  value       = var.backend == "r2" ? "auto" : var.aws_region
}

output "op_item_title" {
  description = "1Password item title that holds the credential pair."
  value       = local.op_item_title
}

output "credentials" {
  description = "S3-compatible credential pair. Marked sensitive — read via 1Password in normal operation."
  sensitive   = true
  value = {
    access_key_id     = var.backend == "r2" ? cloudflare_api_token.r2_bucket[0].id : aws_iam_access_key.this[0].id
    secret_access_key = var.backend == "r2" ? sha256(cloudflare_api_token.r2_bucket[0].value) : aws_iam_access_key.this[0].secret
  }
}

output "token_expires_on" {
  description = "RFC 3339 timestamp when the per-bucket token expires. Null for AWS (no auto-expiry)."
  value       = var.backend == "r2" ? time_offset.token_expiry[0].rfc3339 : null
}
