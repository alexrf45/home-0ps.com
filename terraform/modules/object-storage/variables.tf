variable "env" {
  description = "Operating environment: dev, staging, prod, or testing"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod", "testing"], var.env)
    error_message = "env must be one of: dev, staging, prod, testing"
  }
}

variable "app" {
  description = "Application or workload name. Used in bucket naming and the 1Password item title."
  type        = string
  validation {
    condition     = length(var.app) >= 4 && can(regex("^[a-z0-9-]+$", var.app))
    error_message = "app must be >=4 chars, lowercase alphanumeric and hyphens only"
  }
}

variable "backend" {
  description = "Object storage backend. 'r2' uses Cloudflare R2 (lab default); 'aws_s3' provisions an AWS S3 bucket with a dedicated IAM user."
  type        = string
  default     = "r2"
  validation {
    condition     = contains(["r2", "aws_s3"], var.backend)
    error_message = "backend must be 'r2' or 'aws_s3'"
  }
}

variable "op_vault_id" {
  description = "UUID of the 1Password vault that will receive the credential item."
  type        = string
}

# ---------------------------------------------------------------------------
# R2-only variables (ignored when backend = aws_s3)
# ---------------------------------------------------------------------------

variable "cloudflare_account_id" {
  description = "Cloudflare account ID. Required when backend = 'r2'."
  type        = string
  default     = ""
  # Cross-variable validation (Terraform >= 1.9): fail fast if the caller
  # selects the R2 backend but forgets to set the account ID.
  validation {
    condition     = var.backend == "aws_s3" || length(var.cloudflare_account_id) > 0
    error_message = "cloudflare_account_id must be set when backend = 'r2'"
  }
}

variable "location_hint" {
  description = "R2 location hint. Cloudflare honours this as a placement preference, not a strict region binding."
  type        = string
  default     = "enam"
  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.location_hint)
    error_message = "location_hint must be one of: apac, eeur, enam, weur, wnam, oc"
  }
}

variable "storage_class" {
  description = "Default storage class for newly uploaded objects (R2 only)."
  type        = string
  default     = "Standard"
  validation {
    condition     = contains(["Standard", "InfrequentAccess"], var.storage_class)
    error_message = "storage_class must be 'Standard' or 'InfrequentAccess'"
  }
}

variable "token_expiry_days" {
  description = "Days until the per-bucket data-plane API token expires. R2 only; AWS IAM access keys do not auto-expire."
  type        = number
  default     = 90
  validation {
    condition     = var.token_expiry_days >= 1 && var.token_expiry_days <= 365
    error_message = "token_expiry_days must be between 1 and 365"
  }
}

variable "r2_permission_group_id" {
  description = "Cloudflare permission group UUID for 'Workers R2 Storage Bucket Item Write'. Stable, fetch once via the curl one-liner in the module README and store in your tfvars. R2 only."
  type        = string
  default     = ""
  validation {
    # Required only when actually provisioning the R2 backend.
    condition     = var.backend == "aws_s3" || length(var.r2_permission_group_id) == 32
    error_message = "r2_permission_group_id must be a 32-char Cloudflare permission group UUID when backend = 'r2'"
  }
}

# ---------------------------------------------------------------------------
# AWS-only variables (ignored when backend = r2)
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for the S3 bucket. AWS S3 only."
  type        = string
  default     = "us-east-1"
}

variable "versioning" {
  description = "Bucket versioning. AWS S3 only — the Cloudflare provider does not currently expose R2 versioning, so this is a no-op when backend = r2."
  type        = string
  default     = "Enabled"
  validation {
    condition     = contains(["Enabled", "Disabled"], var.versioning)
    error_message = "versioning must be 'Enabled' or 'Disabled'"
  }
}

# ---------------------------------------------------------------------------
# Backend-agnostic
# ---------------------------------------------------------------------------

variable "lifecycle_days" {
  description = "Belt-and-suspenders lifecycle policy: delete objects older than N days. Set higher than the consuming workload's own retention window (e.g. Barman 7d -> set this to 30). 0 disables the rule."
  type        = number
  default     = 30
  validation {
    condition     = var.lifecycle_days >= 0
    error_message = "lifecycle_days must be >= 0"
  }
}

variable "extra_tags" {
  description = "Additional tags merged onto the AWS bucket. Ignored for R2 (no tag support)."
  type        = map(string)
  default     = {}
}
