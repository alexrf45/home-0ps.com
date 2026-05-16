# =============================================================================
# AWS S3 backend
#
# Mirrors the original wallabag-s3-backup module: dedicated IAM user with an
# inline bucket-RW policy, an access key pair written to 1Password under
# "<app>-aws-creds".
# =============================================================================

data "aws_caller_identity" "current" {
  count = var.backend == "aws_s3" ? 1 : 0
}

resource "aws_s3_bucket" "this" {
  count         = var.backend == "aws_s3" ? 1 : 0
  bucket        = local.bucket_name
  force_destroy = contains(["dev", "testing"], var.env)
  tags          = local.tags
}

resource "aws_s3_bucket_versioning" "this" {
  count  = var.backend == "aws_s3" ? 1 : 0
  bucket = aws_s3_bucket.this[0].id
  versioning_configuration {
    status = var.versioning
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  count  = var.backend == "aws_s3" ? 1 : 0
  bucket = aws_s3_bucket.this[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  count                   = var.backend == "aws_s3" ? 1 : 0
  bucket                  = aws_s3_bucket.this[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.backend == "aws_s3" && var.lifecycle_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this[0].id
  rule {
    id     = "delete-after-${var.lifecycle_days}d"
    status = "Enabled"
    filter {}
    expiration {
      days = var.lifecycle_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "bucket_rw" {
  count = var.backend == "aws_s3" ? 1 : 0
  statement {
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [
      aws_s3_bucket.this[0].arn,
      "${aws_s3_bucket.this[0].arn}/*",
    ]
  }
}

resource "aws_iam_user" "this" {
  count = var.backend == "aws_s3" ? 1 : 0
  name  = "${var.env}-${var.app}-backup"
  path  = "/backup/"
  tags  = local.tags
}

resource "aws_iam_user_policy" "this" {
  count  = var.backend == "aws_s3" ? 1 : 0
  name   = "${var.env}-${var.app}-bucket-rw"
  user   = aws_iam_user.this[0].name
  policy = data.aws_iam_policy_document.bucket_rw[0].json
}

resource "aws_iam_access_key" "this" {
  count = var.backend == "aws_s3" ? 1 : 0
  user  = aws_iam_user.this[0].name
}

resource "onepassword_item" "aws_creds" {
  count    = var.backend == "aws_s3" ? 1 : 0
  vault    = var.op_vault_id
  title    = local.op_item_title
  category = "login"

  section {
    label = "aws_credentials"

    field {
      label = "AWS_ACCESS_KEY_ID"
      type  = "CONCEALED"
      value = aws_iam_access_key.this[0].id
    }
    field {
      label = "AWS_SECRET_ACCESS_KEY"
      type  = "CONCEALED"
      value = aws_iam_access_key.this[0].secret
    }
    field {
      label = "AWS_REGION"
      type  = "STRING"
      value = var.aws_region
    }
    field {
      label = "BUCKET_NAME"
      type  = "STRING"
      value = aws_s3_bucket.this[0].id
    }
    field {
      label = "IAM_USER_ARN"
      type  = "STRING"
      value = aws_iam_user.this[0].arn
    }
  }
}
