variable "env" {
  description = "Operating environment of cluster"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "env must be one of: dev, staging, prod"
  }
}

variable "op_vault_id" {
  description = "UUID of the 1Password vault for infrastructure secrets"
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that will own the R2 bucket"
  type        = string
}

variable "location_hint" {
  description = "R2 location hint"
  type        = string
  default     = "enam"
}

variable "lifecycle_days" {
  description = "Belt-and-suspenders sweep: delete objects older than N days. Must comfortably exceed Barman's own retention (lab default 7d)."
  type        = number
  default     = 30
}

variable "token_expiry_days" {
  description = "Days until the per-bucket data-plane R2 token expires. Lab cadence is quarterly."
  type        = number
  default     = 90
}

variable "r2_permission_group_id" {
  description = "Cloudflare permission group UUID for 'Workers R2 Storage Bucket Item Write'. See module README for the one-liner to fetch it; stable across applies."
  type        = string
}
