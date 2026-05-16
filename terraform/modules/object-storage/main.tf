resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.env}-${var.app}-${random_id.suffix.hex}"

  op_item_title = var.backend == "r2" ? "${var.app}-r2-creds" : "${var.app}-aws-creds"

  tags = merge(
    {
      Environment = var.env
      Application = var.app
      ManagedBy   = "terraform"
      Module      = "object-storage"
    },
    var.extra_tags,
  )
}
