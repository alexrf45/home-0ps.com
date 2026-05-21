# Status

!!! info "Manual snapshot for now"
    This page is a **hand-maintained** snapshot. The plan is to make it *live* — see [Making this live](#making-this-live). Until then, treat the live cluster (`kube dev get …`) and Grafana as the source of truth.

_Last hand-updated: 2026-05-20._

## Services

| Service | URL (internal) | Namespace | Auth | State |
| --- | --- | --- | --- | --- |
| Authentik (SSO) | `dev.int.auth.home-0ps.com` | `authentik` | local + IdP | 🟢 Live |
| Grafana | `dev.int.grafana.home-0ps.com` | `monitoring` | OIDC (Authentik) | 🟢 Live |
| FreshRSS | `dev.int.freshrss.home-0ps.com` | `freshrss` | form login | 🟢 Live |
| Homer (dashboard) | `dev.int.homer.home-0ps.com` | `homer` | none (internal) | 🟢 Live |

## Platform

| Layer | Component | State |
| --- | --- | --- |
| Cluster | 6× Talos `v1.13.0` / k8s `v1.35.0` (3 cp + 3 worker) | 🟢 Ready |
| GitOps | Flux — all Kustomizations + HelmReleases | 🟢 Ready |
| Ingress / TLS | Cilium Gateway · `wildcard-tls` (LE production) | 🟢 Ready |
| Secrets | 1Password Connect → ESO | 🟢 Ready |
| Storage | democratic-csi (iSCSI) + local-path · TrueNAS | 🟢 Ready |
| Observability | Prometheus · Tempo · Grafana · Alloy→Loki (off-cluster) | 🟢 Ready |
| Security | Kyverno · Cilium NetworkPolicies | 🟢 Ready · Falco/Trivy ⚪ off |

Legend: 🟢 healthy · 🟡 degraded/partial · 🔴 down · ⚪ not deployed.

## Making this live

Options, roughly in order of effort, to turn this page from a manual table into a real status surface (the reason the site is hosted **in-cluster** — it can reach these endpoints):

1. **Embed Grafana panels** — iframe specific panels (cluster health, per-app up/latency) into this page. Requires Grafana anonymous/embed access or an authenticated proxy. Lowest-effort visual win.
2. **Dedicated status engine** — deploy [Gatus](https://github.com/TwiN/gatus) or Uptime-Kuma as another GitOps app; it probes the HTTPRoutes and exposes a status JSON/page this site can embed or link.
3. **Build-time snapshot** — a CI step queries Prometheus (`up{...}`) and the Flux/CNPG status, renders this table from a template (mkdocs-macros) at build time. Always-fresh-on-deploy without runtime calls.

See [infra/observability.md](infra/observability.md) for what's already scrapeable.
