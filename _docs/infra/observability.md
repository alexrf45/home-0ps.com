# Infra guide: Observability

**Layer:** `observability` (Flux Kustomization, depends on storage, secrets, networking).
**Shape:** metrics + traces in-cluster; logs offloaded to a bare-metal Loki host.
**Phase 0 plan (archived):** `archive/source-docs/observability-phase-0-plan.md`. Status: complete.

---

## Stack

| Signal | Component | Where | Storage / retention |
| --- | --- | --- | --- |
| Metrics | kube-prometheus-stack `78.0.0` (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) | in-cluster `monitoring` ns | Prometheus 50Gi iSCSI / 15d; Alertmanager 5Gi; Grafana 5Gi |
| Traces | Tempo `1.24.4` (single-binary, OTLP) | in-cluster | 30Gi iSCSI / 72h |
| Logs | Grafana Alloy `1.4.0` DaemonSet → **off-cluster Loki** | Alloy in-cluster; Loki on `192.168.20.87` (Portainer stack) | filesystem `/backups/loki` |

CRDs come from `global/crds/prometheus-operator-crds@27.0.0` — the chart sets `crds.enabled: false` per the project CRD pattern.

## Where it lives

| Path | What |
| --- | --- |
| `_lib/observability/kube-prometheus-stack/helmrelease.yaml` | Prometheus/Grafana/Alertmanager; Grafana OIDC (`auth.generic_oauth`); Alertmanager Slack routing; `defaultRules.create: true` |
| `_lib/observability/kube-prometheus-stack/external-secret{,-oidc,-slack}.yaml` | Grafana admin, OIDC client, Slack webhook (all ESO ← 1Password) |
| `_lib/observability/kube-prometheus-stack/prometheusrule-custom.yaml` | custom PrometheusRules |
| `_lib/observability/alloy/{helmrelease,configmap}.yaml` | log DaemonSet + River config |
| `_lib/observability/tempo/helmrelease.yaml` | traces |
| `_lib/observability/tailscale-egress/loki-egress-service.yaml` | cluster → Loki transport |
| `_lib/observability/scrape-configs/` | `truenas-scrapeconfig.yaml` (192.168.20.106), `tailscale-podmonitor.yaml` |

## Logs: why off-cluster

Loki runs on a dedicated Debian host (`192.168.20.87`) so log retention is decoupled from cluster lifecycle and uses the spare 1TB `/backups` partition. The cluster → Loki transport is **Tailscale** (egress service / TS sidecar on the host). Alloy ships logs from every node; Loki backend is filesystem.

> **Lesson — log shippers must run as root.** `capabilities.add` lands in the *bounding* set only on non-root pods, so Alloy/Promtail-style shippers need `runAsUser: 0` to read `/var/log/pods`. See [guides/best-practices.md](../guides/best-practices.md#log-shippers-need-root).

## Auth & alerting

- **Grafana OIDC** via Authentik (`auth.generic_oauth`), roles from entitlements (Admins/Editors/Viewers), `grafana-oidc` ESO secret, local admin retained for break-glass. Setup: [apps/authentik.md](../apps/authentik.md#wiring-an-oidc-consumer-grafana-pattern).
- **Alertmanager → Slack** (`slack-critical`/`slack-warning` receivers, route tree, inhibit rules) + the chart's `defaultRules`.

## Scrape targets

In-cluster ServiceMonitors are auto-discovered. External targets use CRs: TrueNAS via `ScrapeConfig`, Tailscale operator via `PodMonitor`, 1Password Connect via `ServiceMonitor` (`_lib/secrets/onepassword/servicemonitor.yaml`). All confirmed up.

## Open follow-ups

| ID | Item | Action |
| --- | --- | --- |
| O-4 | K8s Warning events → Loki | add `loki.source.kubernetes_events` to `_lib/observability/alloy/configmap.yaml`; **check Alloy SA has `events {get,list,watch}` first**. Highest-ROI add. |
| O-5 | Gateway hardening | strip `Server`/`X-Powered-By`, body-size limits, rate limiting on exposed HTTPRoutes (Cilium L7) |
| O-6 | Periodic posture scans | `popeye` + `kubescape` CronJobs → stdout → Loki |
| O-9 | App dashboards/alerts | per-app once metrics exist (flip Authentik `serviceMonitor.enabled`); app-specific rules (cert expiry, PVC near-full, CNPG not-healthy) |

## Gotchas

- **Grafana RWO PVC + rolling update = `Multi-Attach`** when the new pod lands on a different node. Delete the old pod to break the deadlock; the real fix is `grafana.deploymentStrategy.type: Recreate`.
- Grafana OIDC's in-cluster back-channel depends on the CoreDNS split-horizon forward resolving `dev.int.auth` ([infra/dns.md](dns.md)).
