# Authentik SSO implementation — session handoff

**Status:** Paused mid-implementation. Resume at the "Next steps" section.
**Date paused:** 2026-05-16
**Author:** fr3d (with Claude)
**Scope:** Phases 1–2 of `_docs/sso-authentik-decision.md` —
internal-only Authentik on dev + Grafana OIDC.

## Where we are

Decision docs and Terraform are written and committed-ready, but the
Authentik R2 backup bucket has not yet been applied because the apply
needs one input we don't have yet: the Cloudflare permission group UUID
for "Workers R2 Storage Bucket Item Write".

## What's already done

### Decision documents

- `_docs/sso-authentik-decision.md` — chose Authentik as the IdP, defined
  the architecture, secrets flow, per-app integration plan, and phased
  rollout. **Status: Decided.**
- `_docs/object-storage-r2-vs-s3-decision.md` — chose Cloudflare R2 as
  the default backup-bucket backend with an `aws_s3` escape hatch.
  Captures user answers on location hint (`enam`), token rotation cadence
  (90 days / quarterly), lifecycle policy (`var.lifecycle_days = 30`).
  **Status: Decided.**

### Terraform code

- `terraform/modules/object-storage/` — reusable module with
  `var.backend = "r2" | "aws_s3"`. R2 path creates the bucket, lifecycle
  rule, bucket-scoped API token, and writes a 1Password item using the
  `AWS_*` envvar naming convention so ESO/Barman wiring stays
  backend-agnostic. AWS path mirrors the wallabag-s3-backup pattern.
  Files: `versions.tf`, `variables.tf`, `main.tf`, `r2.tf`, `aws_s3.tf`,
  `outputs.tf`, `README.md`.
- `terraform/dev/authentik-object-storage/` — consumer that calls the
  module with `app = "authentik"`, `backend = "r2"`. Uses the management
  token stored in 1Password under `cf-r2-obj-storage-api-token`. Files:
  `terraform.tf`, `providers.tf`, `variables.tf`, `main.tf`,
  `outputs.tf`, `README.md`, plus user-provided `terraform.tfvars` and
  `remote.tfbackend`.

### What the apply will produce

| Resource | Purpose |
| --- | --- |
| `cloudflare_r2_bucket.this` | Bucket named `dev-authentik-<8-char-hex>`, location `enam`, storage class `Standard` |
| `cloudflare_r2_bucket_lifecycle.this` | 30-day object delete + 7-day multipart abort. **Note:** this resource cannot be destroyed via Terraform — Cloudflare provider limitation; clean up manually if ever needed. |
| `cloudflare_api_token.r2_bucket` | Bucket-scoped data-plane token, 90-day expiry, `Workers R2 Storage Bucket Item Write` permission. |
| `onepassword_item.r2_creds` | 1P item `authentik-r2-creds` with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, `BUCKET_NAME`, `EXPIRES_ON`. |

No AWS resources are touched (all gated on `var.backend == "aws_s3"`).

## The one blocker

The Cloudflare permission group UUID for "Workers R2 Storage Bucket
Item Write" must be added to `terraform/dev/authentik-object-storage/terraform.tfvars`
as `r2_permission_group_id`. Cloudflare's UUIDs are stable, so this is
a one-time fetch.

We dropped the runtime `cloudflare_api_token_permission_groups_list`
data source approach because it hits a user-scoped API endpoint
(`/user/tokens/permission_groups`) that the lab's narrow `cf-r2-obj-storage-api-token`
returns 403 on, and the account-scoped variant requires `Account API
Tokens: Read` which the token also doesn't carry. Variable-based is
both simpler and avoids widening the management token's scope.

## Next steps to resume

### 1. Fetch the R2 permission group UUID (one-time)

Two paths — pick whichever is easier.

**Via API** (works if `cf-r2-obj-storage-api-token` already has `API
Tokens: Read`; if 403, see "Via dashboard" below):

```sh
op run --no-masking -- bash -c '
  curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/user/tokens/permission_groups" \
  | jq -r ".result[] | select(.name == \"Workers R2 Storage Bucket Item Write\") | .id"
'
```

Expected output: a 32-char hex string.

**Via dashboard:** Cloudflare → My Profile → API Tokens → Create
Custom Token → search permissions for "Workers R2 Storage Bucket Item
Write" → open browser devtools → Network tab → inspect the policy
payload when adding the permission; the `id` field is the UUID. (Or
mint a throwaway token and copy the ID from its policy.)

### 2. Add it to tfvars

Append to `terraform/dev/authentik-object-storage/terraform.tfvars`:

```hcl
r2_permission_group_id = "<32-char-uuid-from-step-1>"
```

### 3. Plan + apply

```sh
cd terraform/dev/authentik-object-storage
op run --no-masking -- terraform plan -out=tfplan
op run --no-masking -- terraform apply tfplan
```

Vet the plan against the "What the apply will produce" table above
before applying.

### 4. After apply, confirm

```sh
# 1P item exists
op item get authentik-r2-creds --vault <vault-id> | head

# Bucket exists in Cloudflare dashboard, or:
op run --no-masking -- bash -c '
  curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/accounts/<account-id>/r2/buckets" \
  | jq ".result.buckets[].name"
'
```

The bucket name will surface in `terraform output bucket_name`.

## Remaining task list (5 items)

These map 1:1 to the in-flight TaskList from the paused session.

### 4. Provision Cloudflare WAF rule via Terraform

- New directory `terraform/dev/cloudflare-waf/`.
- Custom ruleset on the home-0ps.com zone restricting
  `auth.home-0ps.com` to US/CA (geo) — per user's answer in the SSO
  decision doc.
- Required API token permissions for this module: `Zone:Zone:Read`,
  `Zone:Zone WAF:Edit`, `Account:Account Rulesets:Edit`. Stored as a
  separate 1P item (don't reuse `cf-r2-obj-storage-api-token` — keep
  storage and edge perms apart).
- This terraform stages the rule but it only takes effect once Phase 4
  (Cloudflare Tunnel + public hostname) lands. Not in scope for this
  session.

### 5. Add Authentik Helm controller manifests

- `_lib/controllers/authentik/{namespace,helmrepository,helmrelease,kustomization}.yaml`.
- Pin chart version (check `goauthentik/helm-charts` upstream for the
  current stable). Server + worker components, external DB pointed at
  the CNPG cluster, ESO-mounted bootstrap + secret-key + db-creds.
- MFA defaults: WebAuthn (Passkeys) + TOTP backup; SMS off (per user).
- Wire into the root `_lib/controllers/kustomization.yaml`.

### 6. Add Authentik application overlay

- `_lib/applications/authentik/{base,overlays/dev}/`.
- `base/`: `namespace.yaml`, `external-secret.yaml` (bootstrap +
  secret-key + db-creds + R2 creds via 1P), `httproute.yaml`
  (`auth.dev.int.home-0ps.com`), maybe `outpost-proxy.yaml` (stub for
  later forward-auth use), `kustomization.yaml`.
- `overlays/dev/`: `database.yaml` (CNPG Cluster with Barman plugin
  pointing at `authentik-r2-creds`), `ob-archiver.yaml` +
  `ob-recovery.yaml` (SOPS-encrypted ObjectStore CRs — pattern from
  archived wallabag overlay), `kustomization.yaml`.
- Add `auth.dev.int.home-0ps.com` to the wildcard cert SANs if needed
  (likely covered by `*.home-0ps.com` since it's only one level deep —
  verify).
- CCNPs: `authentik-default-deny.yaml` + `authentik-allow.yaml` +
  `authentik-cnpg-allow.yaml` in `_lib/security/cilium-network-policies/`
  following the freshrss/cryptpad shape.

### 7. Wire Authentik Flux Kustomization into `_clusters/dev/cluster.yaml`

- Append a new top-level Kustomization (mirror the `freshrss` /
  `cryptpad` shape).
- `dependsOn`: `dns`, `storage`, `networking`,
  `external-secrets-operator`, `secrets`, `security`, `controllers`.
- `postBuild.substituteFrom` references `cluster-config`.
- Add Authentik subdomain to `_clusters/dev/config/cluster-configs.yaml`:
  `AUTHENTIK_SUBDOMAIN: "dev.int.auth"`.

### 8. Document the Authentik recovery flow

- Brief runbook in `_docs/authentik-recovery-runbook.md`.
- Local admin in 1Password, never federated. Steps: where the password
  is, how to log in when the IdP is degraded, how to rotate, what
  Authentik settings to verify after recovery.
- Plus how to rotate the R2 token (already covered in
  `terraform/modules/object-storage/README.md` — link to it).

### Phase 2 — Grafana OIDC (bonus once Phase 1 is verified)

- Edit `_lib/observability/kube-prometheus-stack/helmrelease.yaml`
  `values.grafana.grafana.ini.auth.generic_oauth` block.
- Map Authentik group claim → Grafana org role.
- Keep a local admin (`grafana-admin-credentials` already exists) for
  break-glass.
- Per-app OIDC client secret loop: Authentik generates → copy to 1P →
  ESO into `monitoring` namespace → mount as env vars on Grafana.
- Tracked separately because it needs Authentik to be live first.

## Key references not in code

| Thing | Value |
| --- | --- |
| Management Cloudflare token 1P item | `cf-r2-obj-storage-api-token` |
| R2 backup creds 1P item (will be created) | `authentik-r2-creds` |
| Field naming convention in 1P | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, `BUCKET_NAME`, `EXPIRES_ON` |
| Bucket name pattern | `dev-authentik-<8-char-hex>` |
| R2 location hint | `enam` |
| R2 token TTL | 90 days (quarterly cadence; future auto-rotation tracked in decision doc open follow-ups) |
| Lifecycle sweep | 30 days (well above Barman's own 7-day retention) |
| Authentik internal hostname | `auth.dev.int.home-0ps.com` |
| Public hostname (Phase 4, not this session) | `auth.home-0ps.com` |
| Recovery user | Local admin in 1Password, never federated |
| MFA | WebAuthn + TOTP, SMS off |
| User store | Local (Authentik DB), no LDAP |

## Known gotchas captured during this session

- `cloudflare_r2_bucket_lifecycle` cannot be destroyed via Terraform
  (Cloudflare provider limitation). If you ever rebuild from scratch,
  the lifecycle rule needs manual cleanup via dashboard/API.
- `cloudflare_api_token_permission_groups_list` data source hits a
  user-scoped API endpoint that requires `API Tokens: Read` on the
  caller's token — the lab's `cf-r2-obj-storage-api-token` does not
  have this, hence the variable-based UUID approach.
- The 1Password provider config uses `account = "Fontaine_Shield"`
  (interactive `op` session), matching the legacy wallabag-s3-backup
  pattern. Requires `op` to be signed in (biometric prompt in your
  terminal) before running terraform. The Claude Code shell cannot
  trigger biometric auth — interactive commands must run from your own
  terminal.
- Terraform variable validation supports cross-variable references as
  of Terraform 1.9; the module's `required_version` is `>= 1.10.0`
  which covers this.
