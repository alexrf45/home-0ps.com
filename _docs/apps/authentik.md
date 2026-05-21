# App guide: Authentik (SSO / IdP)

**Role:** Cluster-wide identity provider. Fronts apps with OIDC (native) or forward-auth (outposts).
**Status:** Live on dev (`memphis`) since 2026-05-20. Internal-only at `dev.int.auth.home-0ps.com`.
**Design rationale:** [ADR-0001](../decisions/0001-sso-authentik.md). Recovery: §[Recovery](#recovery-and-day-2). Consumer example: [Grafana OIDC](#wiring-an-oidc-consumer-grafana-pattern).

---

## At a glance

| | |
| --- | --- |
| Chart | `authentik` `2026.2.3` (`https://charts.goauthentik.io`) |
| Components | server + worker (no Redis — Postgres is broker+cache in 2026.x) |
| Database | CNPG `authentik-dev-cluster`, 3 instances, local-path (5Gi data + 2Gi WAL each) |
| Backup | Barman → Cloudflare R2 (`dev-authentik-e53522c0`) — slated to move to CSI snapshots per [ADR-0003](../decisions/0003-cnpg-local-snapshots.md) |
| Secrets | `authentik-env` + `authentik-r2-creds` via ESO ← 1Password |
| Ingress | HTTPRoute on the Cilium Gateway; TLS via the `wildcard-tls` SAN cert |
| Flux Kustomization | `authentik` (top-level, in `_clusters/dev/cluster.yaml`) |

## Where it lives

| Path | What |
| --- | --- |
| `_lib/controllers/authentik/` | Helm chart (server+worker), `helmrelease.yaml` pins `2026.2.3`, `existingSecret: authentik-env`, `postgresql.enabled: false`, `geoip/ingress/serviceMonitor: false`, `nodeSelector: {node: worker}` |
| `_lib/applications/authentik/base/external-secret.yaml` | ESO refs producing `authentik-env` (chart + CNPG) and `authentik-r2-creds` (Barman) |
| `_lib/applications/authentik/base/httproute.yaml` | `${AUTHENTIK_SUBDOMAIN}.home-0ps.com` → server :9000 |
| `_lib/applications/authentik/overlays/dev/database.yaml` | CNPG `Cluster` + `ScheduledBackup` |
| `_lib/applications/authentik/overlays/dev/ob-archiver.enc.yaml` | SOPS-encrypted Barman `ObjectStore` (R2). **No `ob-recovery` in dev** — deferred to prod (see Recovery §3) |
| `_lib/security/cilium-network-policies/authentik-{default-deny,allow,cnpg-allow}.yaml` | Network policy: default-deny + ingress from `reserved:ingress` on 9000 + CNPG operator allow |
| `_clusters/dev/config/cluster-configs.yaml` | `AUTHENTIK_SUBDOMAIN: "dev.int.auth"` |

## How it's deployed

The chart is installed by the `controllers` Flux Kustomization; the app (DB, ESO, HTTPRoute, Barman) by the top-level `authentik` Kustomization, which `dependsOn` controllers, dns, storage, networking, external-secrets-operator, secrets, security.

**Bootstrap ordering gotcha:** the chart consumes `authentik.existingSecret.secretName: authentik-env`. Until the `ExternalSecret` that produces `authentik-env` syncs, server+worker pods CrashLoop with `secret not found` — expected, self-heals once the 1Password item exists. The `controllers` Kustomization has `wait: true` but waits for HelmRelease `Released`, not pod readiness — CrashLooping Authentik does **not** block downstream layers.

## Secrets

One 1Password item `authentik_${ENVIRONMENT}` (HomeLab vault) feeds a single `ExternalSecret` that emits both CNPG-shape and chart-shape keys (CNPG ignores the extra keys):

| 1P field | K8s key(s) | Used by |
| --- | --- | --- |
| `username` / `password` | `username`/`password` + `AUTHENTIK_POSTGRESQL__USER`/`__PASSWORD` | CNPG bootstrap + chart |
| `database` | `AUTHENTIK_POSTGRESQL__NAME` (`authentik`) | chart |
| `host`/`port` | `AUTHENTIK_POSTGRESQL__HOST`/`__PORT` (`authentik-dev-cluster-rw.authentik.svc`:`5432`) | chart (can be hardcoded in the ES template — no secret content) |
| `secret_key` | `AUTHENTIK_SECRET_KEY` | chart — **60+ random chars, NEVER change after install** (cookie signing + user IDs) |
| `bootstrap_email` / `bootstrap_password` / `bootstrap_token` | `AUTHENTIK_BOOTSTRAP_*` | local-admin (`akadmin`) recovery — never federated |

`authentik-r2-creds` (created by Terraform) carries `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_ENDPOINT_URL`/`AWS_REGION`/`BUCKET_NAME`/`EXPIRES_ON` for Barman.

> Per the project rule, ObjectStore manifests are written plaintext and **you** SOPS-encrypt them (`--encrypted-regex '^(data|destinationPath|endpointURL)$'`). Never re-encrypt secrets without confirmation.

## Wiring an OIDC consumer (Grafana pattern)

The repeatable per-app integration (verified end-to-end for Grafana 2026-05-20). Roles map via **per-app entitlements**, not groups (the `groups` property mapping isn't shipped in 2026.x; `profile` already carries group membership; entitlements are per-app and more granular).

1. **Provider** (Applications → Providers → OAuth2/OpenID): Confidential client; Redirect URI (Strict) `https://<app-host>/login/generic_oauth`; record Client ID/Secret. In **Advanced → Selected Scopes** explicitly add `entitlements` (emits the claim the app reads for roles) and `offline_access` (if the app uses refresh tokens).
2. **Application** (Applications → Applications): bind the provider, set Launch URL.
3. **Entitlements** (Application → Application entitlements): one per role, named to match the consumer's `role_attribute_path` JMESPath *exactly* (e.g. `Grafana Admins`/`Editors`/`Viewers`). Bind yourself to the admin one to test.
4. **Credentials → 1Password** item `<app>_oidc_${ENVIRONMENT}` (`client_id`, `client_secret`); ESO syncs to the app namespace.

Full step-by-step (Grafana): archived `archive/source-docs/grafana-oidc-setup.md`.

## Recovery and day-2

Full runbook: archived `archive/source-docs/authentik-recovery-runbook.md`. Highlights:

- **Local-admin break-glass:** `akadmin` is never federated. Log in directly at `/if/flow/default-authentication-flow/` (skip a broken brand redirect) with `bootstrap_password` from 1P; admin UI at `/if/admin/`. If the flow itself is broken, hit the API with `bootstrap_token`. Rotate `bootstrap_password` after any observed login.
- **R2 token rotation** (180-day TTL; watch `EXPIRES_ON`): `terraform apply -target=...cloudflare_api_token.r2_bucket[0] -target=...onepassword_item.r2_creds[0]` in `terraform/dev/authentik-object-storage`; ESO resyncs; bounce the CNPG primary to pick it up immediately.
- **CNPG restore from R2:** dev ships **no** recovery ObjectStore — you'd create one on the spot. CNPG bootstrap is one-shot/immutable: suspend the `authentik` Flux Kustomization, delete the `Cluster` + instance PVCs, switch `database.yaml` to `bootstrap.recovery`, resume, then revert to `initdb` in a follow-up commit.

## Troubleshooting

| Symptom | First check | Likely fix |
| --- | --- | --- |
| Pods CrashLoop `secret not found` | `kube dev -n authentik get externalsecret` | 1P item missing fields / ESO not synced — `describe externalsecret authentik-env` |
| Login flow 500 | server pod logs | custom flow with a missing stage — log in as `akadmin` via default flow URL, inspect bindings |
| Backups not landing in R2 | CNPG primary Barman sidecar logs | token expired (`EXPIRES_ON`) — rotate |
| `dev.int.auth...` NXDOMAIN | ExternalDNS logs / [infra/dns.md](../infra/dns.md) | confirm HTTPRoute + the in-cluster CoreDNS split-horizon forward |
| TLS handshake fails | `describe cert wildcard-tls` | SAN missing — the `*.home-0ps.com` wildcard does **not** cover three-label hosts; the SAN must be explicit |
| Every OIDC user lands as Viewer | provider Selected Scopes + entitlement names | `entitlements` scope missing, name mismatch vs JMESPath, or user not bound |

## Known gotchas & follow-ups

- Authentik 2026.x is **Redis-less** — ignore older docs.
- The wildcard SAN cert covers `dev.int.auth` explicitly (three-label host); don't rely on the wildcard.
- `serviceMonitor.enabled: false` — no metrics/dashboards yet (observability follow-up O-9).
- Public exposure (Cloudflare Tunnel + forward-auth outposts) and the CF WAF rule are future phases, not built.
- DB will migrate to single-instance static iSCSI + CSI snapshots per [ADR-0003](../decisions/0003-cnpg-local-snapshots.md).
