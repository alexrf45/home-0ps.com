# Observability Phase 0 — implementation plan

## Context

Phase 0 of the observability rollout described in `_docs/` decision history (Istio doc): stand up the metrics, logs, and traces backbone *before* introducing any service mesh. Logs are offloaded from the cluster to a dedicated Debian host (`192.168.20.87`, Portainer-managed) so log retention is decoupled from cluster lifecycle and uses the spare 1TB `/backups` partition.

Decisions locked in:

| Decision | Choice |
|---|---|
| Log shipper (in-cluster) | Grafana Alloy DaemonSet |
| Loki location | Bare metal `192.168.20.87`, Portainer stack |
| Loki backend | Filesystem on `/backups/loki` |
| Grafana | In-cluster, bundled with `kube-prometheus-stack` |
| Cluster ↔ Loki transport | Tailscale (sidecar container on the bare-metal host) |
| Tempo (traces) | In-cluster, `freenas-iscsi` PVC |
| Prometheus | In-cluster, `freenas-iscsi` PVC, kube-prometheus-stack |

## Architecture

```
┌─────────────────── k8s cluster ─────────────────┐         ┌─── 192.168.20.87 ───┐
│                                                 │         │                     │
│  kube-prometheus-stack ──┐                      │         │   ┌──────────────┐  │
│   • Prometheus (PVC)     │                      │         │   │  tailscale   │  │
│   • Alertmanager         │                      │         │   │  sidecar     │  │
│   • Grafana ──────────────┐                     │         │   │ (loki host)  │  │
│   • node-exporter        ││                     │         │   └──────┬───────┘  │
│   • kube-state-metrics   ││                     │         │          │ shared   │
│                          ││                     │         │          │ netns    │
│  Tempo (PVC) ────────────┘│                     │         │   ┌──────┴───────┐  │
│                           │                     │         │   │     Loki     │  │
│  Alloy DaemonSet ─────────┼── Tailscale ────────┼─────────┼─▶ │ :3100 (push) │  │
│   (logs from all nodes)   │  (cluster egress    │         │   │              │  │
│                           │   via TS operator)  │         │   │ /backups/loki│  │
│  External targets ◀───────┘                     │         │   └──────────────┘  │
│   • TrueNAS exporter (192.168.20.106)           │         │                     │
│   • 1Password Connect /metrics                  │         └─────────────────────┘
│   • Tailscale operator metrics                  │
│   • Cilium / Hubble / Falco (already exporting) │
└─────────────────────────────────────────────────┘
```

## Cluster-side changes

### 1. New Flux Kustomization layer: `observability`

Add to `_clusters/dev/cluster.yaml` between `storage` (layer 9) and `security` (layer 10):

```yaml
- name: observability
  dependsOn:
    - name: storage
    - name: secrets
    - name: networking
  path: ./_lib/observability
  # standard interval/timeout/healthChecks pattern from existing layers
```

### 2. New directory `_lib/observability/`

```
_lib/observability/
├── kustomization.yaml          # aggregates the four sub-kustomizations
├── namespace.yaml               # monitoring namespace (already used by CRDs)
├── kube-prometheus-stack/
│   ├── kustomization.yaml
│   ├── helmrepository.yaml      # https://prometheus-community.github.io/helm-charts
│   └── helmrelease.yaml         # crds.enabled: false, grafana enabled, persistence on freenas-iscsi
├── tempo/
│   ├── kustomization.yaml
│   ├── helmrepository.yaml      # https://grafana.github.io/helm-charts
│   └── helmrelease.yaml         # tempo single-binary, freenas-iscsi PVC, OTLP receiver enabled
├── alloy/
│   ├── kustomization.yaml
│   ├── helmrepository.yaml      # https://grafana.github.io/helm-charts
│   ├── helmrelease.yaml         # DaemonSet mode
│   ├── alloy-config.yaml        # ConfigMap with Alloy River config (k8s log discovery + Loki sink)
│   └── externalsecret.yaml      # pulls Loki Tailscale URL from 1Password if needed
└── scrape-configs/
    ├── kustomization.yaml
    ├── truenas-scrapeconfig.yaml          # ScrapeConfig CR targeting 192.168.20.106
    ├── onepassword-servicemonitor.yaml    # 1P Connect /metrics
    ├── tailscale-podmonitor.yaml          # Tailscale operator
    └── hubble-servicemonitor.yaml         # Cilium Hubble (already enabled in helm values)
```

### 3. CRDs already present

`global/crds/prometheus-operator-crds@27.0.0` is installed. The kube-prometheus-stack HelmRelease must set `crds.enabled: false` per the project's CRD pattern (`CLAUDE.md`).

### 4. Sizing

| Workload | StorageClass | Size | Retention |
|---|---|---|---|
| Prometheus | `freenas-iscsi` | 50Gi | 15d (default), can extend |
| Alertmanager | `freenas-iscsi` | 5Gi | n/a |
| Grafana | `freenas-iscsi` | 5Gi | dashboards/data sources only |
| Tempo | `freenas-iscsi` | 30Gi | 72h traces |
| Alloy | none (DaemonSet, positions on hostPath) | n/a | n/a |

Total iSCSI consumption: ~90Gi. TrueNAS pool can absorb this.

### 5. External target patterns

- **TrueNAS:** uses Prometheus `ScrapeConfig` CRD (v0.74+) targeting `192.168.20.106:9100` (node_exporter on TrueNAS) and the TrueNAS-specific exporter port. Add CiliumNetworkPolicy egress allow if default-deny lands.
- **1Password Connect:** `ServiceMonitor` on the existing 1P Connect Service in `external-secrets` namespace.
- **Tailscale operator:** `PodMonitor` selecting the operator pod; metrics on `:9001`.
- **Hubble / Cilium / Falco:** ServiceMonitors are already shipped by their respective Helm charts — verify they get picked up (Prometheus serviceMonitorSelector default matches all in the cluster).

### 6. Egress to Loki via Tailscale

Two viable options, choose during implementation:

- **A.** Alloy authenticates to Tailscale directly (via `TS_AUTHKEY` ExternalSecret), reaches `loki.<tailnet>:3100` directly. Cleanest.
- **B.** Use the existing Tailscale operator's egress (`Service` of type `ExternalName` annotated for TS proxy). Reuses cluster's TS plumbing but adds a hop.

Default to **A** unless TS operator already does egress proxying for other services.

## Bare-metal side: Portainer stack on 192.168.20.87

Stack files live in `_hack/portainer/loki/`:

- `docker-compose.yaml` — self-contained: Loki single-binary + Tailscale sidecar, with the Loki config inlined via Compose `configs.content:` so Portainer's Web editor can deploy it as a single file.
- `.env.example` — template for `TS_AUTHKEY` (real `.env` is gitignored).

Deployment via Portainer Stacks → Web editor: paste the compose contents, set `TS_AUTHKEY` in the environment variables panel, deploy. To edit the Loki config later, edit the stack in Portainer and redeploy — the embedded config block is the source of truth.

Storage layout on the host:

```
/backups/loki/
├── chunks/        # log chunks
├── tsdb-index/    # TSDB indexes
├── tsdb-cache/
├── compactor/
└── wal/           # write-ahead log (recovery)
```

Backup of `/backups/loki/` is the user's existing backup process for `/backups`.

## Order of operations

1. **Bare metal first.** Deploy the Loki + Tailscale Portainer stack. Verify it's reachable from a workstation joined to the tailnet (`curl http://loki.<tailnet>:3100/ready`).
2. **CRDs already deployed** — no change needed.
3. **HelmRepositories.** Add `prometheus-community` and `grafana` HelmRepositories (Flux will sync on next reconcile).
4. **kube-prometheus-stack.** Deploy with `crds.enabled: false`, persistence on freenas-iscsi, Grafana with admin password from 1Password via ExternalSecret.
5. **Tempo.** Deploy single-binary, OTLP HTTP/gRPC receivers enabled.
6. **Grafana data sources.** Add via Helm values: Prometheus (in-cluster), Loki (Tailscale URL), Tempo (in-cluster). Linked traces ↔ logs ↔ metrics correlation enabled.
7. **Alloy.** Deploy DaemonSet with Loki Tailscale URL. Verify logs flow.
8. **Scrape configs** for external targets (TrueNAS, 1P, Tailscale).
9. **Default dashboards** ship with the chart — confirm they render.

## Verification

After each step:

- `flux get kustomizations -n flux-system` — observability layer Ready.
- `kubectl -n monitoring get pods` — all Running.
- `kubectl -n monitoring port-forward svc/<grafana> 3000:80` — Grafana loads, data sources green.
- Loki: `curl http://loki.<tailnet>:3100/loki/api/v1/labels` returns `{"status":"success","data":[...]}`.
- Trace: send an OTLP test span via `curl` from inside the cluster to Tempo, query in Grafana.
- Logs: tail Wallabag pod (`kubectl logs -f`), see new lines appear in Grafana Explore against the Loki data source within ~5s.
- Metrics: confirm `up{job="kubernetes-nodes"}` and `hubble_flows_processed_total` are present.

## Critical files modified

- `_clusters/dev/cluster.yaml` — add `observability` layer
- `_lib/observability/**` — new tree (above)
- `_hack/portainer/loki/**` — bare-metal stack files

## Out of scope for Phase 0

- Default-deny CiliumNetworkPolicy refactor (separate plan)
- Application-level exporters (Wallabag PHP-FPM, FreshRSS) — added when those apps are individually instrumented
- Alertmanager routing to Slack/PagerDuty — define alert channels later
- Long-term cold-storage of Loki chunks (e.g. push to TrueNAS S3) — only if `/backups` fills up

## Follow-on Phase 1 triggers

Once Phase 0 is healthy for ~2 weeks, the next moves (independently) are:

- Convert `_lib/security/cilium-network-policies/` to default-deny-per-namespace.
- Add app-level dashboards & alerts for Wallabag / FreshRSS / Obsidian.
- Re-evaluate Istio decision (see `_docs/`-adjacent decision doc / `~/.claude/plans/today-i-d-like-to-piped-teacup.md`).
