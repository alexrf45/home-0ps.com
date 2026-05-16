# authentik-object-storage

Provisions the Cloudflare R2 bucket + scoped R2 API token that backs the
Authentik CNPG cluster's Barman backups. Wraps
`terraform/modules/object-storage/` with `backend = "r2"`.

## What it creates

| Resource | Purpose |
| --- | --- |
| `cloudflare_r2_bucket.this` | Backup bucket, name `dev-authentik-<hex>` |
| `cloudflare_r2_bucket_lifecycle.this` | 30-day sweep + 7-day multipart abort |
| `cloudflare_api_token.r2_bucket` | Bucket-scoped data-plane token (90-day expiry) |
| `onepassword_item.r2_creds` | 1P item `authentik-r2-creds` for ESO |

## Prerequisites

1. **Cloudflare management token** stored in 1Password under
   `cf-r2-obj-storage-api-token`. Token must carry:
   - Account → Workers R2 Storage:Edit
   - Account → API Tokens:Edit
   - Account → Account Settings:Read
2. **1Password CLI** signed in (the provider uses `account = "Fontaine_Shield"`).
3. **Cloudflare account ID** — pass via `-var=cloudflare_account_id=...` or a `.tfvars` file.
4. **S3 state backend** — initialize with `-backend-config=...` (same pattern as the wallabag module had).

## Apply

```sh
cd terraform/dev/authentik-object-storage
terraform init -backend-config=<your backend file>
terraform plan  -var-file=<your tfvars>
terraform apply -var-file=<your tfvars>
```

## After apply

- `terraform output op_item_title` → confirm `authentik-r2-creds` exists in 1Password.
- `terraform output bucket_name` → matches the bucket visible in the Cloudflare R2 dashboard.
- The Authentik CNPG `ObjectStore` manifest in
  `_lib/applications/authentik/overlays/dev/` references the ESO-mounted
  secret derived from this 1P item.

## Token rotation

Tokens expire after 90 days. To rotate:

```sh
terraform apply \
  -target=module.authentik_backup.cloudflare_api_token.r2_bucket[0] \
  -target=module.authentik_backup.onepassword_item.r2_creds[0]
```

ESO picks up the rotated secret on its next refresh; bounce the
Authentik server + worker pods if you want the change to apply
immediately instead of on the next backup cycle.
