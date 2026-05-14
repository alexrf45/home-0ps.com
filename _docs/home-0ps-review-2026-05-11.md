# home-0ps.com Review — 2026-05-11

> Generated: 2026-05-11
> Scope: Status update against `home-0ps-review-2026-04-27.md`, `observability-phase-0-plan.md`, `self-deployment-best-practices.md`, and `thoth-knowledge-app-decision.md`. Live cluster state included.
> Trigger: Periodic review (`/lab-review`). 89 commits since the 2026-04-27 review; cluster reprovisioned ~2026-04-28; observability Phase 0 landed.
> Presentation: a narrative cut of this journey lives as a [presenterm](https://github.com/mfontanini/presenterm) deck at `_docs/talks/home-0ps-journey/slides.md` (`just present` to rehearse, `just notes` for the speaker-notes view, `just html`/`just pdf` to export, `just script` → narration script). Built by `.github/workflows/build-slides.yml`.

---

## Executive Summary

The fresh provision happened and the lab is materially further along than at the last review. The `memphis` dev cluster is up (6 nodes — 3 control-plane + 3 worker — Talos `v1.13.0`, k8s `v1.35.0`, 13d old) with **all 15 Flux Kustomizations green** and **all HelmReleases reconciled**.

**Headline change:** Observability Phase 0 is **complete and live** — the single biggest gap in the 2026-04-27 review (O-1/O-2/O-3 all "Not done") is closed. kube-prometheus-stack, Tempo, Alloy→Loki (bare-metal, via Tailscale), and external scrape configs (TrueNAS, 1Password Connect, Tailscale operator) are all running. Grafana is wired to all three datasources and exposed internally over HTTPS.

**Other deltas since 2026-04-27:**
- **FreshRSS** went from scaffolded → live (CNPG-backed, with probes).
- **obsidian-livesync → Syncthing** — the CouchDB plan was dropped; Syncthing `1.30.0` now handles vault sync (web UI via gateway HTTPRoute, BEP TCP `22000` via a Cilium LoadBalancer).
- **Kyverno policies live in Audit mode** (scoped by `home-0ps.com/policy-target: application` namespace label) + a Tailscale privileged-allowlist policy in Enforce mode.
- **Wallabag** is CNPG-backed, hardened (init-container seeds writable dirs, runs as UID 65534), and stable.
- **CRD pattern formalized** in `global/crds/` per CLAUDE.md.
- **Public-cloud (Hetzner) dirs were added then abandoned** — confirmed dead, cleanup candidate.

**Still open and not moving:** the security-hardening tier from the original roadmap — Falco (H-3), Cilium NetworkPolicies (H-2), ResourceQuotas/LimitRanges (H-4), Trivy. Plus the resilience gaps surfaced by the self-deployment review: zero PodDisruptionBudgets, no `terminationGracePeriodSeconds` on freshrss.

**Post-2026-05-11 amendments:**
- **C-2 reclassified:** the wildcard cert pointing at `letsencrypt-staging` is **intentional for the dev cluster**. A separate wildcard cert on `letsencrypt-production` will be implemented for the prod cluster when it's stood up — staging here keeps us off LE prod's rate limits during dev churn. Not a flip; carry the prod issuer in `_clusters/production/` overlays.
- **Wallabag spun down 2026-05-14** (manifests archived to `_docs/archive/wallabag/`). This closes R-2, R-6 (wallabag was the only probe gap), and R-8, and trims H-1, R-1, R-7 to freshrss/syncthing-only scope. It also fully orphans `redis-operator`, so the idle-operator hygiene item now reads "remove both".

The natural next sprint: **work the security-hardening tier (H-2/H-3/H-4) now that observability can consume the signals; bundle the H-1 freshrss side-fix into whichever PR touches `_lib/applications/freshrss/base/`.** Resilience (PDBs, freshrss grace period) pairs well with H-4. See §3 for the prioritized punch list.

---

## Section 1 — What Changed Since 2026-04-27

| Area | 2026-04-27 state | 2026-05-11 state |
|------|------------------|------------------|
| Cluster | Needed fresh provision | Provisioned ~2026-04-28; Talos `v1.13.0`, k8s `v1.35.0`, 6 nodes, all Flux layers green |
| Flux DAG | 11 layers, `applications` shared | 15 Kustomizations — per-app top-level (`wallabag`, `freshrss`, `syncthing`); `observability` layer added between `storage` and `security` |
| Observability | ❌ Nothing | ✅ **Phase 0 complete** — kube-prometheus-stack `78.0.0` (Prometheus 50Gi iscsi / Alertmanager 5Gi / Grafana 5Gi), Tempo `1.24.4` single-binary (30Gi iscsi), Alloy DaemonSet `1.4.0` → bare-metal Loki on `192.168.20.87` over Tailscale egress; scrape-configs for TrueNAS (`ScrapeConfig`), 1P Connect (`ServiceMonitor`, HTTPS), Tailscale operator (`PodMonitor`). Grafana datasources: Prometheus + Loki + Tempo. Grafana exposed at `dev.int.grafana.home-0ps.com` (gateway HTTPS). |
| Wallabag | Hardening scaffolded, OOMKill risk | Live, CNPG-backed (3-instance cluster, local-path PVCs), Barman→S3 archiver/recovery, init-container seed pattern, runs UID 65534 + `NET_BIND_SERVICE`, `su` passthrough shim. Resource limits raised (1Gi/1000m). Stable since ~2026-05-03 (27 historical restarts from early s6 flapping). |
| FreshRSS | Scaffolded, not wired | Live — `1.27.0-alpine`, CNPG postgres (3-instance, local-path) + 2Gi iscsi app PVC, has readiness/liveness probes, `FRESHRSS_FORCE_REINSTALL` escape hatch, namespace labeled `home-0ps.com/policy-target: application` |
| Vault sync app | obsidian-livesync (CouchDB) scaffolded | **Replaced by Syncthing** `1.30.0` StatefulSet — config PVC 2Gi iscsi + data PVC 30Gi iscsi; web UI via HTTPRoute; BEP TCP `22000` via Cilium LoadBalancer + external-dns. CouchDB plan abandoned. |
| Security policies | All commented out | `_lib/security/kustomization.yaml` enables `kyverno-policies`; `cilium-network-policies` + `falco-rules` + `trivy` still commented. Kyverno: `app-clusterpolicy.yaml` (multiple ClusterPolicies, `validationFailureAction: Audit`, scoped by namespace label) + `tailscale-privileged-allowlist.yaml` (Enforce — narrows privileged to operator `ts-*` StatefulSets / `sysctler` init) + a mutation disabling `enableServiceLinks` on app pods. |
| Storage | "freenas-iscsi CSI" | democratic-csi `0.15.0` for freenas-iscsi (StorageClass `iscsi`), local-path-provisioner, barman-cloud. **CNPG clusters provision on `local-path`, not `iscsi`** (Postgres data + WAL stay node-local). |
| CRDs | prometheus-operator-crds only | `global/crds/`: prometheus-operator-crds `27.0.0`, trust-manager, cnpg-crds `1.28.0`, mariadb-operator-crds `25.8.3`. Convention documented in CLAUDE.md; operators opt out of bundled CRDs. |
| Tailscale | operator only | + `ProxyClass` (userspace) + `ProxyGroups`; egress used for Alloy→Loki. Syncthing went through several exposure iterations (tailnet → cilium gateway HTTPRoute). |
| Public cloud | n/a | `_lib/controllers/hetzner`, `_lib/controllers/hcloud-ccm`, `_lib/networking/hetzner`, `_lib/storage/hetzner`, `_lib/storage/hetzner-csi` added — **then abandoned (confirmed). Not referenced from any cluster Kustomization. Cleanup candidate.** |
| Docs | migration-review + migration-guide + 2026-04-27 review | + `observability-phase-0-plan.md`, `self-deployment-best-practices.md`, `thoth-knowledge-app-decision.md` |

---

## Section 2 — Live Cluster Snapshot (2026-05-11)

```
Nodes:      6 Ready — cp-{200,201,202}, node-{203,204,205} — Talos v1.13.0 / k8s v1.35.0 / containerd 2.2.3
Flux:       15/15 Kustomizations Ready  ·  20/20 HelmReleases Ready
Certs:      wildcard-tls Ready (issuer: letsencrypt-STAGING)  ·  trust-manager, barman-cloud-{client,server}, op-connect-tls all Ready
Workloads:  no pods outside Running/Completed
PVCs:       freshrss (1×2Gi iscsi + 3×5Gi+2Gi-wal local-path) · monitoring (alertmgr 5Gi + grafana 5Gi + prom 50Gi + tempo 30Gi, all iscsi)
            syncthing (2Gi + 30Gi iscsi) · wallabag (3×20Gi+5Gi-wal local-path)
Operators:  cert-manager, trust-manager, cnpg, democratic-csi (×2), external-dns, external-secrets, kyverno,
            mariadb-operator (idle — 0 CRs), redis-operator (idle — 0 CRs), onepassword-connect, prometheus-operator,
            renovate, tailscale-operator
```

Notable from the snapshot:
- **`mariadb-operator` and `redis-operator`** were deployed but had zero CRs after wallabag's spin-down — **both removed in the 2026-05-14 hygiene pass**. See the Hygiene table.
- The wildcard cert is a **staging** cert — intentional for dev (browsers will warn; that's accepted). Prod cluster will get its own `letsencrypt-production`-issued wildcard. See C-2.
- CNPG Postgres on `local-path` means the DB is pinned to a node and not on the iscsi pool — intentional for IOPS, but worth a conscious note in the DR story (Barman→S3 is the safety net).

---

## Section 3 — Open Items Punch List

Grouped by tier. Each item: **ID · what · status · exact location · next action.** This is the "pick up here" list.

### CRITICAL — correctness / data integrity

| ID | Item | Status | Location | Next action |
|----|------|--------|----------|-------------|
| C-2 | Wildcard cert on `letsencrypt-staging` | ✅ Intentional (dev) | `_lib/networking/gateway/tls.yaml:10` | **Not an open item for the dev cluster.** Staging issuer is deliberate to stay off LE prod's rate limits during dev churn — browsers warning on `*.home-0ps.com` is accepted. **Carry-forward for prod bring-up:** when `_clusters/production/` goes live, add a `wildcard-tls` Certificate there that references `letsencrypt-production`, scoped to the prod gateway. Do not flip the dev manifest. |

### HIGH — security hardening

| ID | Item | Status | Location | Next action |
|----|------|--------|----------|-------------|
| H-1 | Kyverno Audit policies + namespace labeling | ⚠️ Side-fix only (wallabag portion moot post-2026-05-14 spin-down) | `_lib/applications/freshrss/base/namespace.yaml` | `_lib/applications/freshrss/base/namespace.yaml` hard-codes `dev-app-gateway: "true"` — switch to `${GATEWAY_NAME}` for consistency with syncthing. |
| H-2 | Cilium NetworkPolicies | ❌ Not started | `_lib/security/cilium-network-policies/` (only a stale `obsidian-couchdb-networkpolicy.yaml`) | Build default-deny-per-namespace + per-app allow rules; uncomment the dir in `_lib/security/kustomization.yaml`. FreshRSS → CNPG (and Alloy → external `192.168.20.87` Loki via Tailscale egress) is the test case. Delete the obsidian-couchdb policy (dead). |
| H-3 | Falco | ❌ Disabled | `_lib/controllers/kustomization.yaml` (`#  - ./falco`) + `_lib/security/kustomization.yaml` (`#- ./falco-rules`) | HelmRelease `8.0.0` is configured for Talos (modern_ebpf, falcosidekick + UI, ServiceMonitors). Observability now exists to consume the metrics → unblocked. Uncomment both, verify the eBPF driver loads on Talos, confirm Prometheus scrapes the ServiceMonitor. |
| H-4 | ResourceQuotas + LimitRanges per namespace | ❌ Not started | none in `_lib`/`global` | Add `ResourceQuota` + `LimitRange` to each app namespace's `base/` (so `LimitRange` defaults apply at admission; dev overlay narrows). Seed values from `kube dev top pod -n <ns>` once Prometheus has ~30d. Pairs naturally with R-1. |
| H-5 | Trivy operator | ❌ Disabled / empty | `_lib/security/trivy/` (empty dir) + `_lib/security/kustomization.yaml` (`#- ./trivy`) | Populate the dir (HelmRelease for trivy-operator), uncomment. Emits vuln + config-audit reports as CRs; wire a Grafana panel / Prometheus metrics. |

### MEDIUM — resilience (from `self-deployment-best-practices.md`)

| ID | Item | Status | Next action |
|----|------|--------|-------------|
| R-1 | PodDisruptionBudgets | ❌ Zero in repo | Add `policy/v1 PodDisruptionBudget` (`maxUnavailable: 1`, label-selected) to `_lib/applications/{freshrss,syncthing}/base/`. Use CNPG's own affinity/maintenance primitives for the DB clusters — don't hand-roll a PDB over CNPG pods. Verify with a `--dry-run=server` drain. |
| R-2 | Wallabag resource limits | ✅ Moot (wallabag spun down 2026-05-14) | — |
| R-3 | HPA | ⏸️ Deferred | All apps are stateful single-replica; no candidate until Thoth's BFF. |
| R-4 | Dual external-dns | ✅ Done | Only the UniFi-webhook variant remains. |
| R-5 | Renovate config | ✅ Done | In-cluster config authoritative; root `renovate.json` intentionally minimal. |
| R-6 | Probe coverage | ✅ Done (post-wallabag) | `syncthing/base/statefulset.yaml` + `freshrss/base/deployment.yaml` both have probes; wallabag (the only gap) is gone. |
| R-7 | `terminationGracePeriodSeconds` | ⚠️ Not set on freshrss | Set 30–60s on `_lib/applications/freshrss/base/deployment.yaml` so PHP-FPM drains in-flight before SIGKILL. Syncthing's StatefulSet termination is handled by the BEP shutdown path. |
| R-8 | Wallabag Redis wiring without a Redis | ✅ Moot (wallabag spun down 2026-05-14) | redis-operator is now fully orphaned — see Hygiene "Idle operators". |

### Observability follow-ups (Phase 0 complete → these are Phase 1)

| ID | Item | Status | Next action |
|----|------|--------|-------------|
| O-4 | K8s Warning events → Loki | ❌ | Add `loki.source.kubernetes_events` to `_lib/observability/alloy/configmap.yaml`. **First check Alloy's SA has `events {get,list,watch}` cluster-wide** — if not, ride the RBAC change in the same commit. Then a Grafana panel on `{job="...kubernetes_events", type="Warning"}`. Highest-value/lowest-effort observability add. |
| O-5 | Cilium Gateway hardening | ❌ | On externally-exposed HTTPRoutes (grafana, freshrss, future thoth): `ResponseHeaderModifier` to strip `X-Powered-By`/`Server`; per-route body-size limits; rate limiting via `CiliumNetworkPolicy` L7 or `CiliumEnvoyConfig` (permissive for syncthing — real-time sync would trip it). Skip Envoy compression until payload sizes warrant it. |
| O-6 | Periodic posture scans | ❌ | `popeye` + `kubescape framework nsa,mitre` CronJobs (daily, low priority class, `concurrencyPolicy: Forbid`) → stdout → Loki. Forcing function for R-1/R-6. |
| O-7 | Alertmanager routing | ❌ | No alert channels defined. Wire Slack/ntfy/email receiver + a starter ruleset (node down, PVC near full, CNPG not-healthy, cert expiry). |
| O-8 | Default-deny CiliumNetworkPolicy | ❌ | Same work as H-2 — the Phase 1 trigger from the observability plan. |
| O-9 | App-level dashboards/alerts | ❌ | FreshRSS, Syncthing — once each app is individually instrumented. |

### Hygiene / cleanup

| Item | Location | Action |
|------|----------|--------|
| Hetzner/public-cloud dirs (abandoned) | `_lib/controllers/hetzner`, `_lib/controllers/hcloud-ccm`, `_lib/networking/hetzner`, `_lib/storage/hetzner`, `_lib/storage/hetzner-csi` | ✅ Removed (working tree). Not referenced by any cluster Kustomization. |
| Stale Cilium policy | `_lib/security/cilium-network-policies/obsidian-couchdb-networkpolicy.yaml` | ✅ Removed (working tree). |
| Wallabag manifests | `_lib/applications/wallabag/` | ✅ Removed 2026-05-14 (archived to `_docs/archive/wallabag/`). Cluster Kustomization entry removed from `_clusters/dev/cluster.yaml`. |
| Placeholder cluster | `_clusters/production/` (config but no apps) | Leave as-is until prod promotion, but be aware it's a stub. Prod-only `wildcard-tls` against `letsencrypt-production` (see C-2) lands here. |
| README drift | `README.md` | ✅ Refreshed. Badges bumped (Talos `v1.13.0`, k8s `v1.35.0`, flux `v2.7.5`). Applications table swapped Wallabag/Homepage/IT-Tools for FreshRSS + Syncthing. MariaDB architecture badge dropped (operator removed); CloudNativePG added. `kubeop` examples updated to freshrss/syncthing. |
| Idle operators | `mariadb-operator`, `redis-operator` | ✅ Removed. Both fully orphaned post-wallabag; zero CRs verified live across all kinds before removal. `_lib/controllers/{mariadb-operator,redis-operator}/` deleted; entries removed from `_lib/controllers/kustomization.yaml`. **Note:** the review's reference to `global/crds/mariadb-operator-crds` was wrong — mariadb CRDs ship from the operator chart (`crds.enabled: true`) and are deleted by `helm uninstall` on prune. |

### Terraform / IaC

| ID | Item | Status | Note |
|----|------|--------|------|
| R1 | Collapse `pve.tf` controlplane/worker duplication | ❌ Not done | The 2026-04-27 "do during provision, zero state cost" window has **closed** (cluster is provisioned). Now this is a state-breaking refactor — either accept `terraform state mv`, or batch it with the next reprovision. |
| R2 | Extract shared Talos machine config | ❌ Not done | Same — drift risk between CP/worker patches persists (worker still lacks the CP-only PSA exemptions block). Batch with R1. |
| R3 | Externalize magic values | ✅ Done | `var.talos` fields for subnets / DNS IP / NTP / pinned extra-manifests. |
| R4 | Cross-variable IP validation | ✅ Done | Node IPs / VIP / cluster DNS validated against their CIDRs at plan time. |
| R5 | Worker memory typo `8092` | ⚠️ Module fixed, root not | `terraform/dev/talos-pve-v3.1.0/variables.tf` fixed; root `terraform/dev/variables.tf` + `terraform.tfvars` still carry `8092`. tfvars overrides the default so it's a no-op live — tidy next time tfvars is edited. |
| R6 | `bootstrap.sh` removal | ✅ Done | Deleted; SOPS-age seeding handled by `kubernetes_secret.sops_age` in `terraform/dev/main.tf`. |
| R7 | Module README drift | ❌ Not done | README claims `fluxcd/flux ~> 1.5.0` (pin is `~> 1.7.6`) and `local_sensitive_file` exports (actually 1Password). Bring into agreement. |

### Manual / non-GitOps

| Item | Status | Note |
|------|--------|------|
| Beelink S13 BIOS power-loss policy = "Power On" | ❓ Unverified | Per `self-deployment-best-practices.md` §7 — combined with Proxmox HA this gets the cluster to "self-recovers from a power blip". Note completion here once done. |
| notes-backup → TrueNAS cron | ⏳ Pending | `_hack/scripts/syncthing-backup.sh` works from the workstation (zvol expansion + `norecovery` fixes landed); still needs porting to a TrueNAS-native cron once the user is ready. |
| system-upgrade-controller for Talos upgrades | ⏸️ Hack-only | `_hack/scripts/upgrade.sh` + `_hack/yaml/system-upgrade-controller.yaml` exist but SUC isn't deployed via Flux. NICE-TO-HAVE: formalize into `_lib/controllers/`. |

---

## Section 4 — Thoth (unified knowledge app) — Status

Still **pre-decision**. `_docs/thoth-knowledge-app-decision.md` captures the 2026-05-03 design conversation. No commitment to build. It's the planned anchor that justifies the **service mesh decision** (Istio Ambient is the user-preferred long-term choice; adopt at step 3 of the phased build, after 1–2 services exist as bare deployments).

Pick-up point: the **"Open questions to research before next session"** list (9 items) — sync model deep-dive, article-extraction parity with wallabag's `graby`, CRDT escape hatch, GPU node feasibility, Istio Ambient + long-lived gRPC streams, auth strategy, Swift+gRPC vs REST, external-AI cost ceiling, DR for MinIO-backed notes.

Net-new infra it would require: MinIO, Meilisearch, NATS, Ollama (CPU→GPU), Istio Ambient, optional GPU node in Proxmox.

---

## Section 5 — Suggested Next Sprint

In order, cut at natural stopping points:

1. **Hygiene batch** — ✅ Landed (working tree, awaiting commit): Hetzner dirs + stale obsidian-couchdb policy deleted; `mariadb-operator` + `redis-operator` removed; README badges + applications table refreshed.
2. **H-1 side-fix + R-7 freshrss** — switch `_lib/applications/freshrss/base/namespace.yaml` from hard-coded `dev-app-gateway` to `${GATEWAY_NAME}`; add `terminationGracePeriodSeconds: 30–60` to the freshrss Deployment. Single small PR. (C-2 dropped: staging issuer is intentional for the dev cluster; prod gets its own `letsencrypt-production` wildcard at prod bring-up.)
3. **H-4 + R-1** — ResourceQuota/LimitRange + PodDisruptionBudget per app namespace (freshrss, syncthing), one PR per app.
4. **H-3** — enable Falco; verify the eBPF driver on Talos and the ServiceMonitor scrape.
5. **O-4** — K8s Warning events → Loki via Alloy (check RBAC first). Highest ROI of the observability follow-ups.
6. **H-2 / O-8** — default-deny CiliumNetworkPolicy + per-app allow rules; delete the stale obsidian-couchdb policy in the same PR. Biggest single piece of remaining security work.
7. **H-5** — Trivy operator.
8. **O-5 / O-6 / O-7** — gateway hardening, posture-scan CronJobs, Alertmanager routing.
9. (Parallel, low-priority) **Terraform R1/R2/R7** — batch for the next reprovision; **notes-backup → TrueNAS cron**; **BIOS power-loss** check.

---

## Section 6 — Files Referenced

| File | Why it matters |
|------|----------------|
| `_clusters/dev/cluster.yaml` | 15-Kustomization DAG; `observability` layer; per-app application Kustomizations |
| `_clusters/dev/config/cluster-configs.yaml` | `cluster-config` ConfigMap — app versions, subdomains, `GATEWAY_NAME`, storage params |
| `_lib/networking/gateway/tls.yaml` | Line 10: `letsencrypt-staging` — **intentional for dev** (C-2). Prod cluster will declare its own `wildcard-tls` against `letsencrypt-production`. |
| `_lib/applications/freshrss/base/namespace.yaml` | Hard-codes `dev-app-gateway` instead of `${GATEWAY_NAME}` (H-1 side fix) |
| `_lib/applications/freshrss/base/deployment.yaml` | Needs `terminationGracePeriodSeconds` (R-7) |
| `_lib/security/kustomization.yaml` | `kyverno-policies` on; `cilium-network-policies`, `falco-rules`, `trivy` commented (H-2/H-3/H-5) |
| `_lib/controllers/kustomization.yaml` | `falco` commented (H-3); `mariadb-operator` + `redis-operator` entries removable; `hetzner`/`hcloud-ccm` subdirs are dead |
| `_lib/security/kyverno-policies/` | `app-clusterpolicy.yaml` (Audit, namespace-scoped) + `tailscale-privileged-allowlist.yaml` (Enforce) |
| `_lib/security/cilium-network-policies/obsidian-couchdb-networkpolicy.yaml` | Stale — for a service replaced by Syncthing (cleanup, bundle with H-2) |
| `_docs/archive/wallabag/` | Archived manifests from the 2026-05-14 spin-down (for possible restore) |
| `_lib/observability/` | kube-prometheus-stack / tempo / alloy / scrape-configs / tailscale-egress — Phase 0 (complete) |
| `_lib/observability/alloy/configmap.yaml` | Where `loki.source.kubernetes_events` goes (O-4) |
| `_lib/controllers/{hetzner,hcloud-ccm}`, `_lib/networking/hetzner`, `_lib/storage/{hetzner,hetzner-csi}` | Abandoned public-cloud dirs (cleanup) |
| `_hack/scripts/syncthing-backup.sh` | Workstation-validated notes backup; pending port to TrueNAS cron |
| `terraform/dev/talos-pve-v3.1.0/{pve.tf,talos.tf,variables.tf}` | R1/R2 refactors (now state-breaking); R5 root-vs-module typo; R7 README drift |
| `_docs/observability-phase-0-plan.md` | Phase 0 plan — now complete; Phase 1 triggers at the bottom |
| `_docs/self-deployment-best-practices.md` | Source of R-1/R-6/R-7, O-4/O-5/O-6, BIOS item |
| `_docs/thoth-knowledge-app-decision.md` | Anchor-app design + mesh decision; 9 open research questions |
| `_docs/home-0ps-review-2026-04-27.md` | Prior review — superseded by this one |
| `_docs/talks/home-0ps-journey/slides.md` | presenterm deck — narrative version of this review for publishing on luvandre.com |
