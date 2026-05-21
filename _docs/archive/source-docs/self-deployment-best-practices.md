# Self-Deployment best practices — applied to home-0ps

Distilled from Yunus Koçyiğit's *Self-Deployment for Software Developers* (v1.1.0, Ch. 22–25), reconciled against the current lab state (Talos + Flux + Cilium Gateway + CNPG + ESO/1Password + freenas-iscsi + kube-prometheus-stack/Loki/Tempo).

The PDF was written for a single-server `k3s` install with `nginx-ingress` and `ufw`. A lot of what it recommends is already either solved by the lab's distribution choices or replaced by a stronger primitive. This guide only flags the items that are **missing** or **partially implemented**, plus the few places where the PDF's advice still applies verbatim.

## TL;DR — what to actually do

In rough priority order. Each line maps to a section below.

1. **Add `PodDisruptionBudget` + `terminationGracePeriodSeconds` to every stateful app** (wallabag, freshrss, syncthing, CNPG clusters). Drains today are unsafe — there is no PDB anywhere in `_lib/`.
2. **Add `ResourceQuota` + `LimitRange` per application namespace.** No app namespace is bounded today; one runaway pod can starve the cluster.
3. **Audit and tighten probes** on freshrss/wallabag/syncthing. Only two manifests in `_lib/applications/` reference any probe at all.
4. **Wire Kubernetes Warning events into Loki** via Alloy (`loki.source.kubernetes_events`). The cluster generates events nobody reads.
5. **Add rate limiting + compression at Cilium Gateway** for externally exposed routes (grafana, freshrss, future thoth). Currently bare HTTPRoutes.
6. **Add a periodic `popeye` / `kubescape` CronJob** that reports into Loki/Grafana. Ch. 25.12 — these tools have real ROI on a lab targeting prod-ready posture.
7. **Verify Beelink S13 BIOS power-loss policy = "Power On"** on all 6 nodes (Ch. 25.14 — the one home-server tip the PDF gets exactly right).

Everything else from the PDF is already covered, replaced by a stronger primitive, or not applicable. Details below.

---

## What's already aligned (no action)

| PDF chapter | Lab equivalent | Why no action |
|---|---|---|
| 25.01 Use Ansible | Terraform + Flux + Renovate (GitOps) | GitOps replaces config-management tooling. Adopting Ansible would be a regression. |
| 25.03 Use bash | `~/.zsh/kubeop.sh` | Already wraps every cluster command. |
| 25.04 ufw + fail2ban | Talos read-only OS, no SSH, kube API restricted | Talos's threat model is stricter than ufw on Ubuntu. Nothing to add. |
| 25.05 sshuttle | Tailscale operator | Tailscale gives you the same VPN access with mesh routing. Already deployed. |
| 25.08 unattended-upgrades | system-upgrade-controller (Talos image upgrades) + Renovate (chart/CRD upgrades) | Both layers are automated and pinned. |
| 25.13 Don't use `latest` | Renovate + version-pinned `HelmRelease` | Enforced by tooling. |
| 25.15 Hosting provider services | TrueNAS storage, Cilium L2 announcement (floating-IP equivalent), Proxmox HA | Self-hosted analogues are in place. |
| 25.16 Put related resources together | kustomize base/overlay layout in `_lib/applications/<app>/` | Already the convention. |
| 25.18 Dashboard tools | Grafana (kube-prometheus-stack), k9s via `k9s-op` | Both in use. |
| 25.19 Use operators | cert-manager, trust-manager, ESO, 1P Connect, CNPG, mariadb-operator, redis-operator, prometheus-operator, Cilium, Tailscale, Renovate | Heavily leveraged. |
| 22.* DB backups via CronJob + Kopia | CNPG → Barman Cloud → S3 | Stronger pattern (continuous WAL archival, PITR) than `pg_dump` on a CronJob. Wallabag's pre-CNPG backup CronJob still exists for non-Postgres state. |
| 23.02 Deployment strategies | Default RollingUpdate via Flux | Sufficient for single-replica stateful apps. Argo Rollouts / Flagger have no ROI until there is a multi-replica request-handling service (the Thoth BFF would be the first candidate). |

---

## Gaps to address

### 1. PodDisruptionBudgets + termination grace (Ch. 23.01, 25.11)

**Problem.** `_hack/scripts/upgrade.sh` drains nodes during Talos upgrades. There is **zero** PDB in the repo (`grep -rn "kind: PodDisruptionBudget" _lib global` → empty). A drain on the node hosting the wallabag MariaDB or the syncthing StatefulSet evicts it immediately with no in-flight protection.

**Action.** For each stateful workload, add a `PodDisruptionBudget` and an explicit `terminationGracePeriodSeconds` in its base kustomization:

```yaml
# _lib/applications/<app>/base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: <app>
spec:
  maxUnavailable: 1            # single-replica → drain blocks until manually allowed
  selector:
    matchLabels:
      app.kubernetes.io/name: <app>
```

For DB-backed apps (wallabag, freshrss), bump grace to 60–120s so PHP-FPM finishes in-flight requests before SIGKILL (PDF p. 612).

CNPG's `Cluster` CR has its own `affinity` + maintenance window settings — use the operator's primitives, not a hand-rolled PDB.

**Verification.** `k8sop dev kubectl get pdb -A` should list one per stateful app. After adding, dry-run a drain: `kube dev drain <node> --dry-run=server --ignore-daemonsets --delete-emptydir-data`.

### 2. ResourceQuota + LimitRange per app namespace (Ch. 25.06)

**Problem.** No quota anywhere. A misconfigured `requests:` on a future Thoth pod (or a poisoned image via Renovate) can drain CPU/memory across the cluster.

**Action.** Add a `ResourceQuota` + `LimitRange` to each app namespace's base:

```yaml
# _lib/applications/<app>/base/quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: <app>
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    persistentvolumeclaims: "10"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: <app>-defaults
spec:
  limits:
    - type: Container
      default:        { cpu: 500m, memory: 512Mi }
      defaultRequest: { cpu: 50m,  memory: 64Mi  }
      max:            { cpu: 2,    memory: 4Gi   }
```

Tune per-app from `kubectl top pod -n <ns>` baselines (Ch. 25.06 step 3). Start loose, tighten once Prometheus has 30 days of data.

Order matters: `LimitRange` defaults are applied at admission, so put quotas in the **base**, not an overlay — the dev overlay then only narrows them.

### 3. Probe audit (Ch. 23.01)

**Problem.** `grep -l 'Probe' _lib/applications/` returns only two files. The PDF's pattern (p. 610) is right: `readinessProbe` + `livenessProbe` with the liveness on a longer `initialDelaySeconds`, both hitting the same `/healthz`.

**Action.** Per app:

| App | Probe approach |
|---|---|
| wallabag (PHP-FPM/nginx) | `httpGet /` on the nginx container, `tcpSocket :9000` on the FPM container, both with `initialDelaySeconds: 30`. |
| freshrss (PHP-FPM/nginx) | Same shape as wallabag. |
| syncthing | `httpGet /rest/noauth/health` on `:8384` — Syncthing exposes this without auth. |
| CNPG `Cluster` | The operator wires `pg_isready`-equivalent probes; do not override. |

`startupProbe` is overkill for any of these — none take >30s to come up. Avoid the readiness-probe trap on PostgreSQL (PDF p. 610): `pg_isready` does not check replication or WAL state, so don't reuse it as a wallabag dependency probe — let CNPG's status drive that.

### 4. Kubernetes events → Loki (Ch. 25.17)

**Problem.** `kubectl events --types=Warning` is the cheapest cluster-health signal in existence and nothing in the lab consumes it. Falco watches syscalls, not API events.

**Action.** Add a Loki source to the existing Alloy DaemonSet config (already deployed — see `_lib/observability/alloy/`):

```alloy
loki.source.kubernetes_events "events" {
  log_format = "logfmt"
  forward_to = [loki.write.loki.receiver]
}
```

Then in Grafana add a panel: `{job="loki.source.kubernetes_events", type="Warning"}`. Optionally an Alertmanager rule on `count_over_time({...} |= "FailedScheduling" [10m]) > 0`.

This is the single highest-value, lowest-effort observability add in the whole list.

### 5. Cilium Gateway hardening (Ch. 25.09)

**Problem.** PDF Ch. 25.09 spends 14 pages on nginx-ingress hardening: gzip/brotli, rate limiting via `limit_req_zone`, `proxy_buffering`, `client_body_buffer_size`, `hide-headers: X-Powered-By`. None of that translates 1:1 to Cilium Gateway, but the *intent* does.

**Action — what's portable:**

- **Rate limiting.** Cilium Gateway supports rate limits via `CiliumEnvoyConfig` or (cleaner) the upstream Gateway API `RateLimitPolicy` GEP once it lands. Until then, attach a `CiliumNetworkPolicy` with L7 `http.headers` matching to externally exposed routes. Start with `~10 req/s` per source IP for grafana/freshrss; permissive for syncthing (real-time sync would trip it).
- **Compression.** Envoy has `envoy.filters.http.compressor` — wire via `CiliumEnvoyConfig` if you observe payload sizes worth compressing. Grafana dashboards are JSON and benefit; freshrss feed XML benefits more. Skip until you actually see slow loads.
- **Header hiding.** Add `ResponseHeaderModifier` filter to each `HTTPRoute` to strip `X-Powered-By`, `Server`. Trivial change.
- **Body size limits.** Set on a per-route basis — wallabag and freshrss have legitimate large-POST cases (article content, OPML import).

Don't try to port the nginx `proxy_cache` config. CDN-style caching belongs in Cloudflare in front of the Tailscale funnel, not in Cilium Gateway. If page latency becomes a real complaint, Cloudflare → Tunnel → Gateway is the right shape.

### 6. Periodic posture scans (Ch. 25.12)

**Problem.** The lab targets "production-ready" posture but has no recurring sanity-check. Manual k9s + Falco alerts are not the same as a scheduled report.

**Action.** Two CronJobs in `_lib/security/` (or new `_lib/audits/`):

- `popeye` — flags missing PDBs, missing probes, naked Deployments, etc. Output to stdout (Loki picks it up).
- `kubescape framework nsa,mitre` — CIS-style scan; emits Prometheus metrics if you use the operator. The operator is meaningful surface area; if you stay non-operator, just JSON output → Grafana log panel.

Daily schedule, low priority class, `concurrencyPolicy: Forbid`, `failedJobsHistoryLimit: 10` (PDF p. 596). Both tools exist in the project's CLAUDE.md ambition statement (Trivy is already deployed) but neither is wired up to run on a schedule.

ROI is real because: (a) the lab is multi-tenant in spirit (apps + observability + future Thoth), (b) Renovate updates change posture invisibly, (c) the report is a forcing function for the gaps in items 1–3.

### 7. BIOS power-loss policy (Ch. 25.14)

**Problem.** PDF p. 741: BIOS default is "Power Off after AC restore". This is the single most under-set option on consumer mini-PCs hosting servers.

**Action.** On each Beelink S13:

> Enter BIOS → Power Management → AC Power Loss → set to **"Power On"** (not "Last State", not "Power Off").

No GitOps for this — manual one-off. Document on completion in `_docs/runbooks/` (no runbook directory exists yet; one-line note in the existing `_docs/home-0ps-review-*.md` is enough). Combined with Proxmox HA, this gets the cluster to "fully self-recovers from a power blip" — the stated lab goal.

---

## What the PDF gets wrong for this lab

A few items where the PDF's recommendation actively conflicts with the established direction:

- **Single-node `k3s`** (Ch. 13). The lab is Talos + 6 nodes specifically to learn HA primitives. Don't downscale.
- **DockerHub / GHCR over self-hosted registry** (Ch. 11). Reasonable default, but if the Thoth path moves forward there's a real case for an in-cluster registry (Harbor or Zot) for the custom BFF/web/mobile-build images — Renovate-pinning a private image catalog against an external registry is more friction than it's worth at homelab scale.
- **`/tmp` cache paths** (footnote 7, p. 750). Talos `/tmp` is `tmpfs` and capped — use a proper `emptyDir` with `medium: Memory` and an explicit `sizeLimit` instead.
- **`kubectl-ai`** (Ch. 25.12.04). Don't connect an LLM with cluster write access to the dev cluster. Read-only via a scoped ServiceAccount is the only acceptable form.

---

## Open questions to resolve before acting

1. Should `PodDisruptionBudget` + `ResourceQuota` live in `_lib/applications/<app>/base/` (per-app), or in a new shared `_lib/governance/` Flux Kustomization that watches all app namespaces? Per-app is simpler; shared is more discoverable. Lean per-app.
2. For HPA (Ch. 25.07): no app in the lab is multi-replica today. Defer until Thoth (where the BFF is the first real candidate). Don't add HPA to wallabag/freshrss — they're stateful single-instance.
3. For the Loki events stream (item 4): does Alloy already have a service account with `events.get/list/watch` cluster-wide? Verify before writing the config — if not, that RBAC change should ride in the same commit.
