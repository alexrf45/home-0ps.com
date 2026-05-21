# ADR-0001: Authentik as the cluster-wide identity provider

- **Status:** Accepted — implemented and verified live (2026-05-20)
- **Date:** 2026-05-14 (decided); 2026-05-20 (live)
- **Deciders:** fr3d
- **Related:** [ADR-0002](0002-object-storage-r2.md) (R2 backs the Authentik DB), [ADR-0005](0005-thoth-knowledge-app.md) (designs OIDC in from day one). Operational detail in [apps/authentik.md](../apps/authentik.md).

## Context

FreshRSS, Grafana, and future apps need a credible auth posture for external exposure. Each app has its own auth story — FreshRSS form-login, Grafana local users + native OIDC, Homer no auth at all. Bolting a per-app auth proxy on is messy and leaves the dashboard/notes apps without a real boundary. The alternative — "twelve app passwords in 1Password" — does not scale and gives one no central place for users, MFA, or access policy.

## Decision

Adopt **Authentik** as the single cluster-wide IdP. Apps integrate via two patterns:

1. **Native OIDC** where supported (Grafana, FreshRSS ≥ 1.26, CryptPad).
2. **forward-auth (outpost proxy)** where the app has no/weak native auth (Homer, internal dashboards).

The decision to expose an app **externally** is also the decision to put it behind SSO; internal-only `dev.int.*` apps may keep their existing auth. North-south ingress stays on the Cilium Gateway; public exposure (future) is via Cloudflare Tunnel → Gateway → HTTPRoute.

## Rationale

| Option | Verdict |
| --- | --- |
| **Authentik** | **Chosen.** OIDC + SAML + LDAP + forward-auth in one binary; maintained Helm chart; web UI for policy/user/app management; de-facto r/selfhosted choice. |
| Pocket-ID | Passkey-only — no SAML/LDAP, thin policy engine. Boxes us in. |
| Authelia | Strong forward-auth, improving OIDC, but file-driven config (no UI to add apps) and partial SAML. |
| Keycloak | Production-grade but heavy (Java + DB); operational/UX tax unjustified at lab scale. |
| Cloudflare Access | Vendor-locked, no LDAP, auth happens at CF edge — a layer in front of Authentik, not a replacement. |

Authentik runs as its own top-level Flux Kustomization (chart `2026.2.3`), CNPG-backed, with server + worker components. Per-app roles are mapped via **entitlements**, not groups (see [ADR-0006 note in apps/authentik.md] — the `groups` property mapping isn't shipped in 2026.x; the `profile` scope already carries group membership, entitlements are per-app and more granular).

## Consequences

**Positive**
- One place for users, MFA (WebAuthn + TOTP, SMS off), and access policy.
- Grafana OIDC live and verified end-to-end; the per-app provider/application/entitlement pattern is now proven and repeatable.
- Local-admin (`akadmin`) break-glass account, never federated, documented in the recovery runbook.

**Negative / trade-offs**
- Authentik is now a hard dependency for any externally-exposed app's login path — its availability matters.
- The per-app OIDC client-secret loop is manual (Authentik generates → copy to 1Password → ESO into the app namespace). Automating via the Authentik Terraform provider is a deferred follow-up.

**Non-obvious facts learned**
- **Authentik 2026.x is Redis-less** — Postgres serves as DB *and* Celery broker/cache. Older docs mentioning Redis are stale.
- The final blocker for Grafana OIDC was **DNS, not OIDC** — the in-cluster back-channel to `dev.int.auth` NXDOMAIN'd until the CoreDNS split-horizon forward landed. See [infra/dns.md](../infra/dns.md).

**Open follow-ups**
- Phase 4 public exposure: Cloudflare Tunnel + forward-auth outposts (not built).
- Cloudflare WAF rule for the public auth hostname (`terraform/dev/cloudflare-waf/`, not built).
- Authentik `serviceMonitor.enabled` is `false` — no metrics/dashboards yet.

## References

- Full decision essay (archived): `archive/source-docs/sso-authentik-decision.md`
- Implementation record (archived): `archive/source-docs/authentik-sso-implementation-handoff.md`
- Operational guide: [apps/authentik.md](../apps/authentik.md)
