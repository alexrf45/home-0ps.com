resource "onepassword_item" "wallabag_aws_creds" {
  vault    = var.op_vault_id
  title    = "wallabag-aws-creds"
  category = "login"

  section {
    label = "aws_credentials"

    field {
      label = "AWS_ACCESS_KEY_ID"
      type  = "CONCEALED"
      value = aws_iam_access_key.key.id
    }

    field {
      label = "AWS_SECRET_ACCESS_KEY"
      type  = "CONCEALED"
      value = aws_iam_access_key.key.secret
    }

    field {
      label = "AWS_ROLE_ARN"
      type  = "STRING"
      value = aws_iam_role.backup_role.arn
    }
  }
}
