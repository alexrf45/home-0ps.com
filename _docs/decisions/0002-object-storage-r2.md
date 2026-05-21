# ADR-0002: Cloudflare R2 as the default object-storage backend

- **Status:** Superseded for the CNPG backup path by [ADR-0003](0003-cnpg-local-snapshots.md) (2026-05-20). The reusable Terraform module is retained as a generic capability.
- **Date:** 2026-05-16
- **Deciders:** fr3d
- **Related:** [ADR-0001](0001-sso-authentik.md) (Authentik was the first consumer), [ADR-0003](0003-cnpg-local-snapshots.md) (reverses the CNPG backup decision).

## Context

Wallabag's Barman backups lived on AWS S3 via a one-off Terraform module that hard-coded the AWS provider, IAM user/role, and a 1Password item. The same shape was needed for Authentik's CNPG backups and any future durable off-cluster store. Re-implementing per app is dead-weight, and pins the lab to AWS at a time when its posture (Cloudflare DNS, Tunnels, an existing CF API token) skews toward Cloudflare.

## Decision

Build **one reusable module** at `terraform/modules/object-storage/` with a `backend` toggle (`r2` | `aws_s3`); **default to Cloudflare R2**. The AWS path is retained as an escape hatch for any future workload that needs an S3-only feature (KMS, STS/AssumeRole, cross-region replication). Authentik's bucket was the first consumer, exercising the module and the Barman-on-R2 path end-to-end.

## Rationale

The decisive line item is **egress: R2 is $0/GB, AWS is $0.09/GB after 100 GB/mo.** Backup restores and WAL replays from off-cluster are free on R2. R2 is also ~35% cheaper on storage and has a generous always-free tier (10 GB + 1M Class A + 10M Class B every month). The features AWS has that R2 lacks — KMS, STS, cross-region replication — are not in the CNPG-backup threat model (keys live in ESO-rotated 1Password secrets; DR is single-rack). S3-API compatibility (SigV4, multipart, lifecycle, versioning) keeps Barman/CNPG/Velero/restic working unchanged and avoids lock-in.

Resolved parameters: location hint `enam`; token TTL 90→180 days (lab cadence); lifecycle sweep 30 days (well above Barman's 7-day retention).

## Consequences

**Positive**
- Backend-agnostic ESO/Barman wiring via `AWS_*` env-var naming regardless of backend.
- One bill (Cloudflare, already paying for DNS/Tunnels); fewer surfaces to monitor/rotate.

**Negative / trade-offs**
- Single-region durability per bucket; coarser per-bucket IAM than S3; no KMS.
- `cloudflare_r2_bucket_lifecycle` **cannot be `terraform destroy`'d** (provider limitation) — manual dashboard cleanup on teardown.
- The Cloudflare permission-group UUID had to be pinned in tfvars (`2efd5506f9c8494dacb1fa10a3e7d5b6`) because the runtime lookup endpoint 403s under the narrow management token.

**Why this was superseded for CNPG**
ADR-0003 moves the CNPG backup path to local CSI VolumeSnapshots (ZFS), driven by the privacy/self-hosting requirement ("data shouldn't have to come down from S3"). This module is **kept** — it remains the right tool for a *future* genuine off-site need (offsite DR copy, Loki archive, Velero). The Authentik R2 bucket itself is slated for teardown once VolumeSnapshot backups are proven.

## References

- Full decision essay (archived): `archive/source-docs/object-storage-r2-vs-s3-decision.md`
- Module: `terraform/modules/object-storage/README.md`
- Storage guide: [infra/storage.md](../infra/storage.md)
