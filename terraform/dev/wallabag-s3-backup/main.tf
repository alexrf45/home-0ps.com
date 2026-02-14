terraform {
  backend "s3" {}
}


data "aws_caller_identity" "current" {}

provider "aws" {}

provider "onepassword" {
  account = "Fontaine_Shield"
}

module "wallabag" {
  source      = "./module/"
  env         = var.env
  app         = var.app
  username    = var.username
  path        = var.path
  versioning  = var.versioning
  op_vault_id = var.op_vault_id
}
