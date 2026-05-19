# object-storage

Reusable Terraform module that provisions a single object-storage bucket plus
a scoped credential pair for backup / archive workloads. Supports two
backends:

| Backend | Use when |
| --- | --- |
| `r2` (default) | Lab default. Zero egress, lower per-GB storage cost, free tier covers homelab usage. |
| `aws_s3` | A consumer needs an S3-only feature (KMS, STS/AssumeRole, cross-region replication). |

See `_docs/object-storage-r2-vs-s3-decision.md` for the full trade-off
analysis and decision context.

## Inputs

| Variable | Default | Notes |
| --- | --- | --- |
| `env` | — | `dev` / `staging` / `prod` / `testing` |
| `app` | — | App name; used in bucket naming and 1P item title |
| `backend` | `r2` | `r2` or `aws_s3` |
| `op_vault_id` | — | 1Password vault that receives the credential item |
| `cloudflare_account_id` | `""` | Required when `backend = "r2"` |
| `location_hint` | `enam` | R2 location: `apac` / `eeur` / `enam` / `weur` / `wnam` / `oc` |
| `storage_class` | `Standard` | R2: `Standard` or `InfrequentAccess` |
| `token_expiry_days` | `90` | R2 token TTL. Lab cadence is quarterly. |
| `aws_region` | `us-east-1` | AWS S3 only |
| `versioning` | `Enabled` | AWS S3 only — R2 versioning is not yet exposed by the provider |
| `lifecycle_days` | `30` | Belt-and-suspenders sweep. Must comfortably exceed the consumer's own retention (e.g. Barman 7d). `0` disables. |
| `extra_tags` | `{}` | Merged onto AWS bucket tags; ignored for R2 |

## Outputs

| Output | Notes |
| --- | --- |
| `backend` | `r2` or `aws_s3` |
| `bucket_name` | Final bucket name (uniform across backends) |
| `endpoint_url` | S3-compatible endpoint URL (empty for AWS) |
| `region` | `auto` for R2; AWS region for S3 |
| `op_item_title` | 1P item that holds the credentials |
| `credentials` | Sensitive `{ access_key_id, secret_access_key }` |
| `token_expires_on` | RFC 3339 timestamp (R2 only) |

## Example — R2 (lab default)

```hcl
module "authentik_backup" {
  source                = "../../modules/object-storage"
  env                   = var.env
  app                   = "authentik"
  backend               = "r2"
  op_vault_id           = var.op_vault_id
  cloudflare_account_id = var.cloudflare_account_id
  location_hint         = "enam"
  lifecycle_days        = 30
  token_expiry_days     = 90
}
```

## Example — AWS S3 (escape hatch)

```hcl
module "compliance_archive" {
  source      = "../../modules/object-storage"
  env         = var.env
  app         = "compliance-archive"
  backend     = "aws_s3"
  op_vault_id = var.op_vault_id
  aws_region  = "us-west-2"
}
```

## 1Password item contents

For both backends, the credential is written under the title
`<app>-<backend>-creds` (e.g. `authentik-r2-creds`, `compliance-archive-aws-creds`).

The field names use the `AWS_*` convention so the same ExternalSecret /
Barman config works against either backend:

| Field | R2 value | AWS S3 value |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` | API token ID | IAM access key ID |
| `AWS_SECRET_ACCESS_KEY` | SHA-256(API token value) | IAM secret access key |
| `AWS_ENDPOINT_URL` | `https://<account>.r2.cloudflarestorage.com` | (not set) |
| `AWS_REGION` | `auto` | configured AWS region |
| `BUCKET_NAME` | bucket name | bucket name |
| `EXPIRES_ON` | token RFC3339 expiry | (not set) |
| `IAM_USER_ARN` | (not set) | IAM user ARN |

## One-time R2 enablement (account-level, not module-level)

The R2 product must be activated in the Cloudflare dashboard before any
R2 API call will succeed — token scopes alone are not sufficient. If
the account has never used R2 before, the first apply will fail with:

```
code 10042: Please enable R2 through the Cloudflare Dashboard.
```

Fix once per account: Cloudflare dashboard → **R2 Object Storage** →
**Enable R2** / **Purchase R2** → accept terms. The free tier covers
homelab usage but billing info has to be on file.

## Required Cloudflare API token scopes

The token configured in the *calling* root module's `cloudflare` provider
needs to be able to:

| Permission | Why |
| --- | --- |
| Account → Workers R2 Storage:Edit | Create/delete buckets, set lifecycle |
| User → API Tokens:Edit | Mint the per-bucket scoped data-plane token (the create endpoint is `POST /user/tokens`, so the grant is User-scoped, not Account-scoped) |
| Account → Account Settings:Read | Resolve the account ID |

Keep this token **separate** from the DNS-01 / ExternalDNS token
(`Zone:DNS:Edit` + `Zone:Zone:Read`) already in use by cert-manager and
ExternalDNS, so a leak of one credential does not compromise the other.

## Fetching `r2_permission_group_id`

The Cloudflare permission group UUIDs are stable. The module asks the caller
to pass `r2_permission_group_id` directly so we don't have to grant the
management token `API Tokens: Read` (which the `*_permission_groups_list`
data sources require). Fetch the ID once and pin it in your tfvars.

Two ways to look it up:

**Via API (token needs `API Tokens: Read` for this one-off call):**

```sh
op run --no-masking -- curl -s \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/permission_groups" \
  | jq -r '.result[] | select(.name == "Workers R2 Storage Bucket Item Write") | .id'
```

**Via dashboard:** Cloudflare → My Profile → API Tokens → Create Token →
Custom Token → "Permissions" dropdown → search "Workers R2 Storage Bucket
Item Write" → inspect the network request's payload to see the `id`. (Or
just create a throwaway token via the UI and inspect the resulting policy.)

The resulting UUID looks like `2efd5506f9c8494dacb1fa10a3e7d5b6` (32 hex
chars). Drop it into your tfvars under `r2_permission_group_id` and it
stays valid until Cloudflare reorganizes the permission registry (which
they have not done in the lifetime of R2).

## Required AWS permissions (S3 backend only)

The calling module's `aws` provider credentials need:

- `s3:*` on the bucket name pattern `${env}-${app}-*`
- `iam:CreateUser`, `iam:DeleteUser`, `iam:PutUserPolicy`, `iam:DeleteUserPolicy`, `iam:CreateAccessKey`, `iam:DeleteAccessKey`, `iam:TagUser` for the `/backup/` path

## Token rotation flow (R2)

The per-bucket token expires after `token_expiry_days` (default 90).
Rotation procedure:

1. `terraform apply -target=module.<consumer>.cloudflare_api_token.r2_bucket[0]` — this taints and re-issues the token.
2. The module writes the new `AWS_*` pair to the same 1Password item, so ESO pulls the rotated secret on its next refresh cycle (`refreshInterval`).
3. Bounce the consuming pod if you want the refresh to apply immediately rather than on next backup cycle.

Future automation tracked in `_docs/object-storage-r2-vs-s3-decision.md`
under "Open follow-ups" — a scheduled Terraform run + ESO refresh trigger
to remove the human step.

## Migration from `terraform/dev/wallabag-s3-backup/`

That bespoke module is now superseded. New consumers call this module
directly; the wallabag-s3-backup directory and its state can be
`terraform destroy`'d as a separate cleanup PR.
