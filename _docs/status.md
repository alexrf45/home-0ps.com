# Status

!!! info "Live where it can be"
    The **Live check** column below runs in your browser when this page loads — it
    probes each service over the network, so it reflects whether *you* can reach it
    (works from the LAN where `dev.int.*` resolves). The platform table further down
    is still a hand-maintained snapshot; see [Making this live](#making-this-live).

## Services

| Service | URL (internal) | Auth | Live check |
| --- | --- | --- | --- |
| Authentik (SSO) | `dev.int.auth.home-0ps.com` | local + IdP | <span id="status-authentik">⏳ checking…</span> |
| Grafana | `dev.int.grafana.home-0ps.com` | OIDC (Authentik) | <span id="status-grafana">⏳ checking…</span> |
| FreshRSS | `dev.int.freshrss.home-0ps.com` | form login | <span id="status-freshrss">⏳ checking…</span> |
| Homer (dashboard) | `dev.int.homer.home-0ps.com` | none (internal) | <span id="status-homer">⏳ checking…</span> |
| Docs (this site) | `dev.int.docs.home-0ps.com` | none (internal) | <span id="status-docs">⏳ checking…</span> |

!!! warning inline end "Heads-up"
    A 🔴 here means *your browser* couldn't reach the host (often: you're off-LAN, or
    internal DNS isn't resolving), not necessarily that the pod is down. Cross-check
    with the platform view / Grafana.

The check is a best-effort `no-cors` reachability probe with a 6s timeout — it can
tell "the host answered" from "no response," not the HTTP status code.

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

The service checks above are live. To make the **platform** table live too (it can't be
probed from the browser), in rough order of effort — and the reason the site is hosted
**in-cluster**, where it can reach these endpoints:

1. **Embed Grafana panels** — iframe cluster-health / per-app panels. Needs Grafana
   `allow_embedding` + anonymous (or same-domain) access. Lowest-effort visual win.
2. **Dedicated status engine** — deploy [Gatus](https://github.com/TwiN/gatus) as a
   GitOps app; it probes the HTTPRoutes server-side and exposes a status page/JSON to
   embed here (more accurate than the browser probe, includes history/uptime%).
3. **Build-time snapshot** — a build step queries Prometheus (`up{...}`) + Flux/CNPG
   status and renders this table from a template. Fresh on every deploy, no runtime calls.

See [infra/observability.md](infra/observability.md) for what's already scrapeable.
