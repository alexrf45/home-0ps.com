# Infra guide: Networking

**Layer:** `networking` (Flux Kustomization, depends on `secrets`).
**Stack:** Cilium (CNI + L2 + Gateway API), cert-manager ClusterIssuers, Tailscale operator.
**North-south:** Cilium Gateway. **East-west:** Cilium (a future service mesh — Istio Ambient — is anchored to [ADR-0005](../decisions/0005-thoth-knowledge-app.md)).

---

## Cilium (CNI / L2 / Gateway)

> **Cilium is NOT managed by Flux.** It's rendered by Terraform `helm_template` at plan time and shipped as a Talos **inlineManifest** — bootstrap-only. To change the **live** cluster, edit the Cilium DaemonSet/ConfigMap directly; to change **future bootstraps**, edit `terraform/dev/talos-pve-v3.1.0/cilium_config.tf`. Don't look for a Cilium HelmRelease in `_lib/`.

- **L2 announcement** provides floating LB IPs (the hosting-provider "floating IP" equivalent).
- **Gotcha — `externalTrafficPolicy: Local` breaks low-replica LBs:** with few replicas the L2 leader node and the pod node can mismatch → connection refused. Default to `Cluster`.

## Gateway API

| Path | What |
| --- | --- |
| `_lib/networking/gateway/gatewayclass.yaml` | Cilium GatewayClass |
| `_lib/networking/gateway/gateway.yaml` | `${GATEWAY_NAME}` = `dev-app-gateway` in the `networking` ns |
| `_lib/networking/gateway/tls.yaml` | `wildcard-tls` Certificate (see SNI note) |

Apps attach via `HTTPRoute` with `parentRefs` → the gateway; namespaces opt in with the `${GATEWAY_NAME}: "true"` label (gateway `allowedRoutes` selector).

**Gotchas:**
- **Multi-cert SNI doesn't work** on Cilium Gateway — it serves the first `certificateRef` for all SNIs. Use **one wildcard SAN cert**: extend `dnsNames` rather than adding a second `certificateRef`. The `*.home-0ps.com` wildcard does **not** cover three-label hosts, so each `dev.int.X` host is an explicit SAN (`dev.int.{auth,grafana,homer,freshrss}`).
- **Gateway proxy → backend uses `reserved:ingress` identity.** CCNPs gating gateway backends need `fromEntities: [ingress]`; `host`/`remote-node` only covers kubelet probes.

## TLS and ClusterIssuers

`_lib/networking/clusterissuers/` — `letsencrypt-production` + `letsencrypt-staging`, DNS-01 via Cloudflare (`cf-secrets.yaml`, SOPS-encrypted). The dev wildcard is on **`letsencrypt-production`** (flipped 2026-05-16 — no browser warnings). Internal service-to-service TLS uses the internal CA — see [infra/secrets-pki.md](secrets-pki.md).

## Tailscale

`_lib/networking/tailscale/` — operator (chart `1.96.5`), `proxyclass.yaml`, `proxygroups.yaml`. Used for operator-only access to things that should never face the public internet.

> **Gotcha — Service proxies require privileged.** The Tailscale operator's `sysctler` init container is hardcoded privileged, which collides with the restricted PSA / Kyverno posture. For non-HTTP workloads, prefer exposing via a Cilium Gateway HTTPRoute instead of a Tailscale Service proxy. An allowlist entry (`_lib/security/kyverno-policies/tailscale-privileged-allowlist.yaml`) carves out the exception where the proxy is genuinely needed.

## Related open items

- O-5 gateway hardening (headers, body limits, rate limiting) — [infra/observability.md](observability.md).
- Public exposure via Cloudflare Tunnel + the WAF rule — future SSO phase ([ADR-0001](../decisions/0001-sso-authentik.md)).
