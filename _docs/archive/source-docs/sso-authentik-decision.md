# SSO with Authentik — decision document

**Status:** Decided. Authentik is the SSO/IdP for home-0ps.com.
**Date:** 2026-05-14
**Author:** fr3d
**Scope:** dev cluster (memphis) first; pattern carries to prod.

## Problem

FreshRSS and Grafana need to be reachable from outside the home network for
real-world testing, and additional apps (CryptPad, Homer, future Thoth) will
need the same. Each app has its own auth story (FreshRSS form-login, Grafana
local users + native OIDC, Homer has no auth at all) — bolting an auth proxy
on per-app gets messy and leaves the dashboard/CryptPad without a credible
externally-exposed posture.

A single IdP that fronts every externally-exposed app with the same identity
gives one place to manage users, MFA, and access policies — and avoids the
"twelve app passwords stored in 1Password" sprawl.

## Decision

Adopt **Authentik** as the cluster-wide IdP. Apps integrate via two patterns:

1. **Native OIDC** when the app supports it (Grafana, FreshRSS ≥ 1.26, CryptPad).
2. **forward-auth (outpost proxy)** when the app has no native auth or its auth
   is too weak to expose externally (Homer, internal dashboards, anything else).

Both patterns terminate against the same Authentik instance. The decision to
expose an app externally also decides whether it gets SSO — internal-only apps
on `dev.int.*` can keep their existing auth.

## Why Authentik (not the alternatives)

| Option | Verdict |
| --- | --- |
| **Authentik** | **Chosen.** OIDC + SAML + LDAP + forward-auth in one binary, has a maintained Helm chart, web UI for policy/user/app management, active development, the de-facto choice in r/selfhosted for the same use case. |
| Pocket-ID | Passkey-only is appealing but boxes us in — no SAML, no LDAP, limited policy engine. Reconsider if/when only passkey apps remain. |
| Authelia | Strong forward-auth story, OIDC support has improved, but config is file-driven (less ergonomic than a UI for adding apps), and SAML support is still partial. |
| Keycloak | Production-grade, but heavier (Java + DB), and the operational/UX tax is poorly justified at homelab scale. Revisit if we ever need realm-per-tenant or RH support paths. |
| Cloudflare Access | Vendor-locked, no LDAP, no on-prem auth boundary — the auth check happens at Cloudflare's edge. Fine as a layer in front of Authentik but not a replacement. |

## Architecture

```
        Internet  ────►  Cloudflare Tunnel ──►  Cilium Gateway (TLS)  ──►  HTTPRoute
                                                                              │
                                                ┌─────────────────────────────┤
                                                │                             │
                                                ▼                             ▼
                                           Authentik                  App (FreshRSS, Grafana, ...)
                                          (server + worker)                   │
                                                ▲                             │
                                                └─── OIDC redirect ───────────┘
                                                     OR forward-auth callback
```

- **Authentik server** — handles the user-facing flows (login, MFA, OIDC
  endpoints, admin UI).
- **Authentik worker** — background jobs (LDAP sync, expressions, e-mail).
- **Authentik database** — Postgres (CNPG, mirrors the wallabag pattern we are
  decommissioning).
- **Outposts** — Kubernetes-deployed proxy outposts that implement
  forward-auth for apps that need it; one outpost can front many apps.

External exposure happens at the gateway, not at the app. Apps that the user
opens externally get a hostname under a public-facing zone fronted by
Cloudflare Tunnel; the tunnel forwards to the Cilium Gateway, which dispatches
to the HTTPRoute (Authentik or app).

## Deployment layout (GitOps)

```
_lib/
├── controllers/
│   └── authentik/                ← Helm chart, server + worker
│       ├── helmrelease.yaml
│       ├── helmrepository.yaml
│       ├── kustomization.yaml
│       └── namespace.yaml
└── applications/
    └── authentik/
        ├── base/
        │   ├── cnpg-cluster.yaml         ← Authentik DB
        │   ├── external-secret.yaml      ← 1P-sourced bootstrap secrets
        │   ├── httproute.yaml            ← auth.home-0ps.com
        │   ├── outpost-proxy.yaml        ← embedded outpost binding
        │   └── kustomization.yaml
        └── overlays/dev/
            └── kustomization.yaml
```

A new Flux Kustomization `authentik` slots into `_clusters/dev/cluster.yaml`
under Layer 7, depending on `dns`, `storage`, `networking`,
`external-secrets-operator`, `secrets`, `security`, and `controllers` (for the
CNPG Cluster CRD).

## Secrets

| Secret | Source | Used for |
|--------|--------|----------|
| `authentik-secret-key` | 1Password → ESO | Authentik cookie signing |
| `authentik-bootstrap` | 1Password → ESO | Initial admin credentials |
| `authentik-db-creds` | CNPG-managed | Postgres password (random) |
| `cloudflare-tunnel-token` | 1Password → ESO | Tunnel credentials for the public hostnames |
| Per-app OIDC client secret | Authentik generates → exported to 1P → ESO into app namespace | App-side OIDC config |

The per-app client secret loop is the only manual step: Authentik generates
the client, the secret is copied into 1Password, and the app's ExternalSecret
pulls it in. We can revisit automating this with the Authentik Terraform
provider later.

## Per-app integration plan

### Grafana (native OIDC)

Grafana lives inside `kube-prometheus-stack`. Add a `grafana.ini` block via
the HelmRelease `values.grafana.grafana.ini.auth.generic_oauth` keys:
- `enabled = true`
- `name = Authentik`
- `client_id` / `client_secret` from a secret mount
- `auth_url`, `token_url`, `api_url` pointing at `auth.home-0ps.com`
- `role_attribute_path` mapping Authentik group claims → Grafana org role

Disable Grafana local logins for external traffic; keep an admin local
account behind a `grafana.ini` flag for emergency access.

### FreshRSS (native OIDC, since 1.26)

FreshRSS supports OIDC via environment variables (`OIDC_ENABLED`,
`OIDC_PROVIDER_METADATA_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
`OIDC_X_FORWARDED_HEADERS`). Wire these into the FreshRSS Deployment from a
secret mounted via ExternalSecret. The form-login stays available as a
fallback but can be disabled once OIDC is verified.

### Future apps (CryptPad, Homer, Thoth)

- **CryptPad** — has native SSO (OIDC/SAML) on the Enterprise/admin tier.
  Verify the OSS image supports the keys we need; fall back to forward-auth
  on the admin route if not.
- **Homer** — no auth. Pure forward-auth outpost.
- **Thoth** — design native OIDC in from day one.

## External exposure

Use **Cloudflare Tunnels** (`cloudflared` running in-cluster as a
DaemonSet/Deployment) for the public hostnames:

- `auth.home-0ps.com` — Authentik login UI
- `rss.home-0ps.com` — FreshRSS (OIDC-only)
- `grafana.home-0ps.com` — Grafana (OIDC-only)

The tunnel forwards to the Cilium Gateway's internal LB IP and the gateway
dispatches by hostname to the right HTTPRoute. Internal `dev.int.*`
hostnames stay LAN-only via the existing gateway.

Tailscale stays in the mix for operator-only access to things that should
never face the public internet (Adminer, Falco UI if added, Loki UI).

## Open questions / follow-ups

1. **MFA policy.** Authentik supports TOTP, WebAuthn, and SMS. Default to
   WebAuthn (Passkeys) + TOTP backup; SMS off. Confirm before rollout.
2. **User store.** Local-only (Authentik DB) is fine for the homelab; LDAP
   sync is not justified yet.
3. **Authentik backup.** Postgres goes to the Barman R2 bucket pattern (same
   as wallabag was). Authentik media volume (icons, etc.) on iSCSI PVC, no
   external backup needed.
4. **GeoIP/IP allow-list.** Cloudflare WAF rule for the `auth.home-0ps.com`
   hostname — restrict to US/Canada or to known ASN ranges to cut down on
   credential-stuffing attempts.
5. **Recovery user.** Local admin in 1Password, never federated. Document
   the recovery flow.

## Phased rollout

1. **Phase 1 — Deploy Authentik.** CNPG cluster + Helm release + internal
   HTTPRoute on `auth.dev.int.home-0ps.com`. Validate the admin login.
2. **Phase 2 — Wire Grafana OIDC.** Lowest-risk integration; Grafana is
   already in-cluster and has mature OIDC.
3. **Phase 3 — Wire FreshRSS OIDC.** Confirms the per-app secret loop.
4. **Phase 4 — Public exposure.** Stand up Cloudflare Tunnel; expose
   `auth.`, `rss.`, `grafana.home-0ps.com`.
5. **Phase 5 — Forward-auth outpost.** First consumer is Homer once it's
   deployed; CryptPad follows on the same outpost.

Each phase is its own PR / Flux reconciliation.
