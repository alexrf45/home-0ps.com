output "caller_arn" {
  value = data.aws_caller_identity.current.arn
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "s3_bucket_arn" {
  value       = aws_s3_bucket.db_backup.arn
  description = "The ARN of the S3 bucket"
}

output "bucket_name" {
  value       = aws_s3_bucket.db_backup.id
  description = "The name of the bucket"
}

output "bucket_url" {
  value = aws_s3_bucket.db_backup.bucket_domain_name
}

output "user_arn" {
  value       = aws_iam_user.user.arn
  description = "iam user arn"
}

output "aws_credentials" {
  sensitive = true
  value = {
    access_key_id     = aws_iam_access_key.key.id
    secret_access_key = aws_iam_access_key.key.secret
    role_arn          = aws_iam_role.backup_role.arn
  }
}
