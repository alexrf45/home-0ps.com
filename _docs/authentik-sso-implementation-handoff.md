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

### 8. ~~Document the Authentik recovery flow~~ ✅ DONE (2026-05-18)

- Runbook landed at `_docs/authentik-recovery-runbook.md`. Covers
  local-admin recovery via `akadmin` + `bootstrap_*` fields in 1P,
  R2 token rotation (links to `terraform/modules/object-storage/README.md`),
  and the wire-in-on-demand recovery ObjectStore flow (since the
  dev overlay no longer ships `ob-recovery` — see the updated
  scope table above).

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

---

## 2026-05-17 session update

### Progress since pause

- ~~Fetch R2 permission group UUID~~ ✅ Done. UUID `2efd5506f9c8494dacb1fa10a3e7d5b6` — stable Cloudflare-wide; pinned in `terraform/dev/authentik-object-storage/terraform.tfvars` as `r2_permission_group_id`.
- ~~Apply `terraform/dev/authentik-object-storage/`~~ ✅ Done. Outputs:
  - `bucket_name = "dev-authentik-e53522c0"`
  - `endpoint_url = "https://3b08781f685f3388d4b1a15485e3bc00.r2.cloudflarestorage.com"`
  - `op_item_title = "authentik-r2-creds"` (HomeLab vault)
  - `token_expires_on = "2026-11-14T03:25:26Z"` (180 days; lab cadence)
- ~~Module README scope correction~~ ✅ Done. The required scope for `POST /user/tokens` is **User → API Tokens : Edit**, not Account-scoped. README at `terraform/modules/object-storage/README.md` patched + added a one-time "Enable R2 in dashboard" prerequisite (10042 error if skipped).
- ~~R2 token rotated mid-session~~ ✅ Done. A buggy `jq` filter leaked the live R2 access key + secret to chat. Token re-issued via `terraform apply -target=module.authentik_backup.cloudflare_api_token.r2_bucket[0] -target=module.authentik_backup.onepassword_item.r2_creds[0]`; leaked pair is dead.
- ~~Task 5 — Authentik Helm controller manifests~~ ✅ Done. New tree at `_lib/controllers/authentik/`:
  - `namespace.yaml` (ns `authentik`, label `app: identity`)
  - `helmrepository.yaml` (`https://charts.goauthentik.io`)
  - `helmrelease.yaml` (chart `2026.2.3` pinned, `targetNamespace: authentik`, `fullnameOverride: authentik`, `authentik.existingSecret.secretName: authentik-env`, `postgresql.enabled: false`, `geoip.enabled: false`, `ingress.enabled: false`, `serviceMonitor.enabled: false`, `nodeSelector: {node: worker}`)
  - `kustomization.yaml`
  - Wired into `_lib/controllers/kustomization.yaml` (added `./authentik` to resources). Manifests yamllint-clean; `kubectl kustomize` renders without name collisions.

### Non-obvious facts captured this session

- **Authentik 2026.x is Redis-less.** The chart dropped the Bitnami Redis subchart — Postgres serves as both DB and Celery broker / cache now. No Redis plumbing needed anywhere in the rollout. Older Authentik docs that mention Redis are stale relative to 2026.x.
- **Chart auto-creates a Secret from `authentik.*` values unless `existingSecret.secretName` is set.** We set it to `authentik-env` so the chart's auto-secret path is bypassed entirely. Until task 6 creates the `ExternalSecret` that produces `authentik-env`, the server + worker pods will CrashLoop with `secret not found` — expected.
- **`controllers` Flux Kustomization has `wait: true`** but it waits for HelmRelease `Released: True`, not pod readiness. CrashLooping Authentik pods will NOT block downstream layer reconciliation.

### Resume tomorrow — order of work

1. **Create 1P item `authentik_${ENVIRONMENT}`** in HomeLab vault (schema below). Without this, task 6's `ExternalSecret`s sit in `SecretSyncedError` and the chart pods can't start.
2. **Decide the 6 open questions in the next subsection.**
3. Resume with the Claude Code session — I'll write task 6 files (base/, overlays/dev/, CCNPs, SAN extension, `AUTHENTIK_SUBDOMAIN`) once questions are settled.
4. **You SOPS-encrypt** the two plaintext `ObjectStore` drafts (`ob-archiver.plain.yaml` → `ob-archiver.yaml`, same for recovery). Per the project rule, I write plaintext; you encrypt. Then update `overlays/dev/kustomization.yaml` to reference the encrypted versions.
5. Task 7 — top-level Flux Kustomization for Authentik in `_clusters/dev/cluster.yaml`. Without this, none of task 6 reconciles.
6. Task 8 — recovery runbook.

### 1P item `authentik_${ENVIRONMENT}` field schema

Mirror the `freshrss-db-creds` ExternalSecret pattern: one 1P item, multiple fields, single `ExternalSecret` produces one K8s Secret with both CNPG-bootstrap-shape and Authentik-chart-shape keys. The chart consumes `AUTHENTIK_*` keys via `existingSecret.secretName`; CNPG `bootstrap.initdb.secret.name` consumes `username` + `password` from the same Secret (CNPG ignores extra keys).

Pattern reference: `_lib/applications/freshrss/base/secrets.yaml` (the `freshrss-db-creds` block).

| 1P field (`property` in ExternalSecret) | Goes to K8s Secret key | Used by | Notes |
| --- | --- | --- | --- |
| `username` | `username` | CNPG bootstrap | Also becomes the Authentik DB owner |
| `username` | `AUTHENTIK_POSTGRESQL__USER` | Authentik chart | Same value as above, exposed under chart's expected key |
| `password` | `password` | CNPG bootstrap | Strong random — `op item create` will generate |
| `password` | `AUTHENTIK_POSTGRESQL__PASSWORD` | Authentik chart | Same value |
| `database` | `AUTHENTIK_POSTGRESQL__NAME` | Authentik chart | Set to `authentik` |
| `host` | `AUTHENTIK_POSTGRESQL__HOST` | Authentik chart | `authentik-${ENVIRONMENT}-cluster-rw.authentik.svc` — can be hardcoded in the ExternalSecret template instead of stored in 1P |
| `port` | `AUTHENTIK_POSTGRESQL__PORT` | Authentik chart | `5432` — same hardcode option |
| `secret_key` | `AUTHENTIK_SECRET_KEY` | Authentik chart | 60+ random chars. **Never change after first install** (cookie signing + user IDs) |
| `bootstrap_email` | `AUTHENTIK_BOOTSTRAP_EMAIL` | Authentik chart | Local-admin (`akadmin`) recovery email — never federated |
| `bootstrap_password` | `AUTHENTIK_BOOTSTRAP_PASSWORD` | Authentik chart | Local-admin initial password — rotate after first login |
| `bootstrap_token` | `AUTHENTIK_BOOTSTRAP_TOKEN` | Authentik chart | API admin token (optional but useful for terraform-managed app configs later) |

Host + port can be hardcoded in the ExternalSecret's per-key value rather than read from 1P — there's no secret content there, just identifiers. If you'd prefer the freshrss approach of storing host/port in 1P for consistency, add them too.

The existing `authentik-r2-creds` 1P item (created by terraform yesterday) already has the right shape for the Barman ObjectStores: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL`, `AWS_REGION`, `BUCKET_NAME`, `EXPIRES_ON`. No 1P work needed for that one — task 6 just writes an `ExternalSecret` referencing it.

### Task 6 open questions (resolve before scaffolding)

1. **Internal hostname** — `dev.int.auth.home-0ps.com` (matches lab convention; produced by `AUTHENTIK_SUBDOMAIN: "dev.int.auth"`) **or** `auth.dev.int.home-0ps.com` (also mentioned in earlier sections of this doc). My default: `dev.int.auth.home-0ps.com`.
2. **1P item creation** — confirm you'll create `authentik_${ENVIRONMENT}` per the schema above before resuming, or have me list it in the open-items tracker. (I won't touch 1P myself.)
3. **CNPG sizing** — `instances: 3`, data 5Gi, WAL 2Gi, daily `ScheduledBackup` at `0 0 * * *`. Same as freshrss/wallabag. OK?
4. **Bootstrap email value** — local-admin recovery email goes in 1P, never federated. You set the value when creating the 1P item; I just reference the field. (Just confirming the model — no answer needed unless you want a different field name.)
5. **Chart container port for CCNP allow rule** — Authentik chart's `server` container exposes 9000 (HTTP) by default; CCNP `authentik-allow` will allow ingress from `reserved:ingress` on 9000. I'll render the chart locally with `helm template` first to confirm before writing the CCNP so the policy matches exactly. OK?
6. **`AUTHENTIK_SUBDOMAIN` substitution scope** — the HTTPRoute (`applications` Flux Kustomization) sees the substitution; the wildcard cert (`networking` Flux Kustomization) doesn't — different `postBuild` scopes. Plan: HTTPRoute uses `${AUTHENTIK_SUBDOMAIN}`, the cert SAN is hardcoded to `dev.int.auth.home-0ps.com`. OK?

### What task 6 will produce (locked-in pre-question scope)

| File | Encryption |
| --- | --- |
| `_lib/applications/authentik/base/external-secret.yaml` (the `authentik-env` + the `authentik-r2-creds` ESO refs) | plain |
| `_lib/applications/authentik/base/httproute.yaml` | plain |
| `_lib/applications/authentik/base/kustomization.yaml` | plain |
| `_lib/applications/authentik/overlays/dev/database.yaml` (CNPG `Cluster` + `ScheduledBackup`, mirrors archived wallabag) | plain |
| `_lib/applications/authentik/overlays/dev/ob-archiver.plain.yaml` (you SOPS-encrypt → `ob-archiver.yaml`) | plain → SOPS |
| ~~`_lib/applications/authentik/overlays/dev/ob-recovery.plain.yaml`~~ — **deferred to prod overlay.** Dev has no historical data to restore from; when promoting to prod, create `_lib/applications/authentik/overlays/prod/ob-recovery.plain.yaml` pointing at the prod R2 bucket (mirror the archiver shape, swap bucket/endpoint/path), then SOPS-encrypt. | n/a (dev) |
| `_lib/applications/authentik/overlays/dev/kustomization.yaml` (refs encrypted versions once you've encrypted them) | plain |
| `_lib/security/cilium-network-policies/authentik-{default-deny,allow,cnpg-allow}.yaml` + kustomization update | plain |
| `_lib/networking/gateway/tls.yaml` — add `dev.int.auth.home-0ps.com` to wildcard cert SANs | plain |
| `_clusters/dev/config/cluster-configs.yaml` — add `AUTHENTIK_SUBDOMAIN: "dev.int.auth"` | plain |

Out of scope for task 6 (own tasks): outpost-proxy stub, top-level Flux Kustomization (task 7), recovery runbook (task 8), ServiceMonitor / PrometheusRules (observability follow-up).
