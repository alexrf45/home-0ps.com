# Object storage backend — R2 vs S3 decision document

**Status:** Decided. R2 is the default backend; module exposes `var.backend`
so any consumer can opt into AWS S3 if a future workload needs an S3-only
feature.
**Date:** 2026-05-16
**Author:** fr3d
**Scope:** All future object-storage consumers in the lab — starting with
the Authentik CNPG backup bucket, replacing the bespoke
`terraform/dev/wallabag-s3-backup/` pattern that shipped with wallabag (now
decommissioned).

## Problem

Wallabag's Barman backups lived on AWS S3, provisioned by a one-off Terraform
module that hard-coded the AWS provider, IAM user, IAM role, and the
`wallabag-aws-creds` 1Password item. The same shape is now needed for:

- **Authentik** — CNPG Postgres backups (the immediate driver).
- **Any future app** that needs durable off-cluster object storage
  (file-server snapshots, Loki archives, Velero, future Thoth blob store).

Re-implementing the wallabag pattern per app is dead-weight repetition, and
pins us to AWS at a moment when the lab's broader posture (Cloudflare DNS,
Cloudflare Tunnels for SSO exposure, Cloudflare API token already minted) is
clearly skewing toward Cloudflare for edge + storage.

A repeatable module that supports either backend lets the lab pick once per
consumer and stay consistent.

## Decision

**Cloudflare R2 is the default backend.** Build one reusable Terraform
module at `terraform/modules/object-storage/` with a `backend` toggle
(`r2` | `aws_s3`) so a future app can pick AWS if it ever needs an
S3-only feature (KMS, cross-region replication, STS), but new consumers
default to R2.

The Authentik bucket lands on R2 first; that exercises the module
end-to-end and proves the Barman-on-R2 path before any other app adopts it.

User confirmed 2026-05-16: R2 with flip-to-AWS escape hatch.

## Why R2 (not AWS S3)

| Dimension | AWS S3 | Cloudflare R2 | Winner for this lab |
| --- | --- | --- | --- |
| **Egress cost** | $0.09/GB to internet after first 100 GB/mo | **$0/GB**, no cap | R2 — restores and WAL replays from off-cluster are free |
| **Storage cost** | $0.023/GB·mo (Standard, us-east-1) | $0.015/GB·mo (Standard) / $0.01 (Infrequent Access) | R2 (~35% cheaper) |
| **Class A ops (PUT/POST/LIST)** | $0.005 / 1k req | $4.50 / M req (= $0.0045/1k) | Roughly even |
| **Class B ops (GET/HEAD)** | $0.0004 / 1k req | $0.36 / M req (= $0.00036/1k) | R2 marginally cheaper |
| **Free tier** | 5 GB storage / 20k GET / 2k PUT for 12 mo | 10 GB storage / 1M Class A / 10M Class B **every month, forever** | R2 — covers all homelab workloads at $0 |
| **S3 API surface** | Reference implementation | S3-compatible (SigV4, GET/PUT/LIST/DELETE, multipart, versioning, lifecycle, object lock, presigned URLs) | AWS in absolute terms; R2 covers everything Barman/CNPG/Velero/restic use |
| **Encryption at rest** | SSE-S3 / SSE-KMS / SSE-C | SSE-AES256 transparent (no KMS) | AWS if you need KMS keys; R2 is enough for backup data |
| **IAM model** | Users, roles, policies, STS, AssumeRole | Account-level API tokens scoped per-bucket; no roles/STS | AWS in expressiveness; R2 simpler for one-operator labs |
| **Versioning / Object Lock / Lifecycle** | Yes | Yes (GA) | Either |
| **Cross-region replication** | Yes | No (single-region per bucket) | AWS — only matters if DR is multi-region |
| **Durability claim** | 11 nines | 11 nines | Either |
| **Terraform provider maturity** | `hashicorp/aws` — battle-tested | `cloudflare/cloudflare` v5.x — `cloudflare_r2_bucket` GA, `cloudflare_api_token` for scoped creds | AWS in maturity, R2 sufficient for the shape we need |
| **Operator burden** | Separate AWS bill, IAM users to rotate, billing surface to monitor | One Cloudflare bill (already paying for DNS / Tunnels) | R2 — fewer surfaces |
| **Vendor lock-in** | S3 is the de-facto open standard | S3-compatible API → can swap back to AWS S3 (or MinIO, Garage, Backblaze B2) without changing app code | Roughly even because of S3 API compatibility |

**The egress line item is the decisive one.** Barman backup volume is
write-heavy (compressed WAL + base backups, ongoing) but read-bursty
during restores. A single DR restore of even a modest 5 GB Postgres
cluster from AWS S3 costs ~$0.45 in egress; from R2 it's free. Over the
lab's lifetime, R2 is meaningfully cheaper, and we lose nothing the
Barman/CNPG path actually consumes.

The features AWS S3 has that R2 lacks — KMS, STS/AssumeRole, cross-region
replication — are not in the CNPG-backup threat model. The keys live in
ESO-rotated secrets pulled from 1Password; we never needed AssumeRole;
cross-region DR is well outside the lab's blast radius (one Proxmox
cluster in one rack).

## What the reusable module looks like

`terraform/modules/object-storage/`

```
terraform/modules/object-storage/
├── README.md                 ← usage, examples, required token scopes
├── variables.tf              ← app, env, backend, versioning, op_vault_id
├── outputs.tf                ← bucket_name, endpoint, credentials (sensitive)
├── main.tf                   ← dispatches to r2.tf or aws_s3.tf based on var.backend
├── r2.tf                     ← cloudflare_r2_bucket + cloudflare_api_token + 1P item
├── aws_s3.tf                 ← aws_s3_bucket + IAM user + IAM access key + 1P item
└── 1password_item.tf         ← shared writer for the credential item
```

**Module interface (proposed):**

```hcl
module "authentik_backup" {
  source      = "../../modules/object-storage"
  env         = var.env                      # dev | staging | prod
  app         = "authentik"
  backend     = "r2"                         # r2 | aws_s3
  versioning  = "Enabled"
  op_vault_id = var.op_vault_id
}
```

**Outputs (uniform across backends):**

| Output | Type | Notes |
| --- | --- | --- |
| `bucket_name` | string | Globally unique: `${env}-${app}-${random_id}` |
| `endpoint_url` | string | For R2: `https://<account>.r2.cloudflarestorage.com`; for S3: empty (Barman defaults to AWS) |
| `region` | string | `auto` for R2, `us-east-1` (or var) for S3 |
| `credentials` | object (sensitive) | `{ access_key_id, secret_access_key }` |

**1Password item naming:**

`<app>-<backend>-creds` — e.g. `authentik-r2-creds` or `authentik-aws-creds`.
Fields: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`,
`AWS_REGION`. The `AWS_*` naming is deliberate: Barman + boto3 read the
same env var names regardless of backend, so the ESO → app wiring stays
backend-agnostic.

### How Barman-on-R2 actually wires up

The CNPG `ObjectStore` CR already supports an `endpointURL` field on the
`s3Credentials` config:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: authentik-dev-cluster-archive
  namespace: authentik
spec:
  configuration:
    destinationPath: s3://dev-authentik-<uuid>/
    endpointURL: https://<account>.r2.cloudflarestorage.com
    s3Credentials:
      accessKeyId:
        name: authentik-r2-creds
        key: AWS_ACCESS_KEY_ID
      secretAccessKey:
        name: authentik-r2-creds
        key: AWS_SECRET_ACCESS_KEY
```

Region is implicit (`auto`); SigV4 signing works against R2 the same way
it does against S3. Barman's compression, retention, and WAL archive
features all work; this is a well-documented community pattern.

### Cloudflare API token scopes (for the R2 path)

The Terraform module needs a token capable of creating R2 buckets and
minting per-bucket API tokens. Required permissions (set once, stored as
`CLOUDFLARE_API_TOKEN` env var or in 1Password as `cloudflare-r2-tf-token`):

| Scope | Permission | Why |
| --- | --- | --- |
| Account | `Workers R2 Storage:Edit` | Create/delete R2 buckets, set lifecycle/versioning |
| Account | `API Tokens:Edit` | Mint per-bucket API tokens for the backup workload |
| Account | `Account Settings:Read` | Resolve the account ID |

This is **separate** from the DNS token already in use for ExternalDNS /
cert-manager DNS-01 (which only needs `Zone:DNS:Edit` and `Zone:Zone:Read`).
Keeping the R2 token scoped narrowly avoids accidentally exposing DNS
write to the storage automation.

## Migration / coexistence

- **Wallabag** is already decommissioned and the AWS bucket is the only
  remaining trace; it can be `terraform destroy`'d once we confirm we don't
  want the historic backup data. Tracked separately as a cleanup task.
- **Existing AWS account** stays open until we're confident R2 covers
  every consumer. No data migration is needed — Authentik is greenfield.
- **Module ships with both backends from day one** so any future app can
  flip without rebuilding. We just default to R2.

## Trade-offs the lab is accepting

1. **Single-region durability.** R2 stores a bucket in one region (with
   internal redundancy). For the lab's DR posture this is fine; if we
   ever need geo-redundant backups we'd add a second R2 bucket in a
   different region hint and run a Barman-style mirror job, or fall back
   to S3 + CRR for that one app.
2. **No KMS.** R2's transparent SSE is AES256 with Cloudflare-managed
   keys. If a future workload demands customer-managed keys for
   compliance reasons, that app can opt into `backend = "aws_s3"`.
3. **Coarser IAM.** R2 tokens are scoped per-bucket and per-permission
   class, not per-action. The bespoke "this user can only GET, that user
   can only PUT" patterns from S3/IAM don't translate. For backup
   workloads where the workload needs both write (archive) and read
   (restore) on the same bucket, this is a non-issue.
4. **Terraform provider risk.** `cloudflare_r2_bucket` is GA but younger
   than `aws_s3_bucket`. If the resource shape shifts under us, we have
   to track provider releases. Renovate already watches provider
   versions in `terraform/dev/terraform.tf`, so the blast radius is
   small.

## Resolved follow-ups (user, 2026-05-16)

1. **Bucket geography.** Default location hint = `ENAM` (eastern North
   America) to match the lab's physical location. Module exposes
   `var.location_hint` for the rare override.
2. **AWS account sunset.** Not in scope — the user uses the AWS account
   for other workloads. Leave it open. Wallabag bucket can still be
   `terraform destroy`'d as a one-off cleanup; the IAM user/role from
   `wallabag-s3-backup/` is the only homelab footprint left.
3. **Token rotation cadence.** **Quarterly (90 days)** on the per-bucket
   tokens minted by the module. The expiry surfaces the credential on
   the rotation cadence; a follow-up will look at automating the
   rotation via Terraform pipeline + ESO secret refresh so the human
   step disappears. Documented in the recovery runbook.
4. **Lifecycle / retention.** Approved. Module exposes
   `var.lifecycle_days` (default `30`). Barman's own retention window
   (currently `7d` for wallabag-style configs) is the primary cleanup;
   R2 lifecycle is the belt-and-suspenders sweep for objects Barman
   leaks (interrupted uploads, abandoned multipart parts, manual test
   writes). Set to comfortably exceed Barman's retention so we never
   delete a live backup.

## Open follow-ups

- **Per-app token automation.** Today the per-bucket Cloudflare token is
  Terraform-managed, but ESO can't pick up a rotated token unless we
  write it back to 1Password (which the module already does). A future
  pass should wire a quarterly Terraform pipeline run + ESO secret
  refresh trigger so the human step disappears.
- **Multi-region replication.** R2 is single-region per bucket. If a
  future workload needs geo-redundant backups, run a Barman-style mirror
  job to a second R2 bucket with a different `location_hint`, or fall
  back to `backend = "aws_s3"` for that one app.

## Phased rollout

1. **Phase A — User picks backend.** This document; produces a binary
   answer (R2 or S3 default).
2. **Phase B — Build the module.** `terraform/modules/object-storage/`
   with both backends supported, default = chosen backend.
3. **Phase C — Provision the Authentik bucket.**
   `terraform/dev/authentik-object-storage/` calls the module with
   `app = "authentik"`; outputs the 1Password item.
4. **Phase D — Wire Authentik CNPG to it.** ObjectStore + ScheduledBackup
   manifests in `_lib/applications/authentik/overlays/dev/` reference
   the ESO-mounted secret.
5. **Phase E — Retire `terraform/dev/wallabag-s3-backup/`.** Once the
   new module is proven, delete the bespoke wallabag TF and (optionally)
   the AWS bucket itself.

## Recommendation summary

Go with R2 as default. The reusable module supports both so the lab keeps
the escape hatch. Authentik is the first consumer; the wallabag pattern
gets archived. Pending your confirmation before I start writing
`terraform/modules/object-storage/`.
