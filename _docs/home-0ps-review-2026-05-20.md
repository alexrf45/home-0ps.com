# home-0ps.com Review — 2026-05-20

> Generated: 2026-05-20
> Scope: Status update against `home-0ps-review-2026-05-11.md`, plus `authentik-sso-implementation-handoff.md`, `storage-strategy-decision.md` (new), `object-storage-r2-vs-s3-decision.md`, `self-deployment-best-practices.md`, `thoth-knowledge-app-decision.md`. Live `memphis` dev cluster surveyed.
> Trigger: Periodic review (`/lab-review`). 27 commits since 2026-05-11; headline = Authentik SSO + Grafana OIDC landed and verified.

---

## Executive Summary

The lab is stable and materially further along on **identity**. The `memphis` dev cluster is healthy — 6 nodes (3 cp + 3 worker, Talos `v1.13.0`, k8s `v1.35.0`, 22d old), **all 14 Flux Kustomizations Ready**, **17/17 HelmReleases Ready**, no pods outside Running/Completed, all 5 certs Ready.

**Headline change:** **Authentik SSO is live and Grafana OIDC works end-to-end** (verified 2026-05-20). Authentik runs as its own top-level Flux Kustomization (chart `2026.2.3`), CNPG-backed, R2 backup wired, internal at `dev.int.auth.home-0ps.com`. Grafana "Sign in with Authentik" completes the token exchange — the final blocker was DNS, not OIDC config (see DNS item below).

**Other deltas since 2026-05-11:**

- **CryptPad dropped.** Spun down 2026-05-19 (`0b145f7`) — but the removal was **partial**: only the Flux Kustomization was deleted. Manifests, 4 `CRYPTPAD_*` config keys, and 2 orphaned CCNPs linger (see Hygiene).
- **CoreDNS split-horizon fix** (`8b3af1f`) — in-cluster `*.home-0ps.com` now resolves via UniFi; this is what unblocked Grafana OIDC's back-channel. Live edit + terraform committed, **not yet applied**.
- **Object-storage module** (`1c2eee2`) + Authentik R2 bucket provisioned.
- **CNPG CCNP** fix (`9c099d9`) — operator → instance-manager ingress on 8000.
- **Wildcard cert** is now `letsencrypt-production` (C-2 closed, done 2026-05-16).
- **New decision doc** `storage-strategy-decision.md` — go single-instance CNPG on static iSCSI zvols + CSI VolumeSnapshots, exit R2/S3. **Decided, not built.**

**Still open and not moving:** the security-hardening tier — Falco (H-3), ResourceQuotas/LimitRanges (H-4), Trivy (H-5) — unchanged since the last two reviews. Resilience gaps persist: zero PodDisruptionBudgets (R-1), no `terminationGracePeriodSeconds` on freshrss (R-7). **Alertmanager routing (O-7) is now resolved** (Slack receivers + default rules live).

**Recommended next sprint:** **Homer (lowest-risk app left, plan ready) + a hygiene bundle** (finish the CryptPad cleanup, apply the CoreDNS terraform). Treat the storage migration (new S-tier) as its own dedicated sprint. See §5.

---

## Section 1 — What Changed Since 2026-05-11

| Area | 2026-05-11 state | 2026-05-20 state |
| --- | --- | --- |
| Identity / SSO | ❌ None | ✅ **Authentik live** — own Flux Kustomization, chart `2026.2.3`, CNPG-backed (3×local-path), Barman→R2 backup, internal `dev.int.auth.home-0ps.com`. Redis-less (Postgres is broker+cache in 2026.x). |
| Grafana auth | Local admin only | ✅ **OIDC via Authentik** — `auth.generic_oauth`, role mapping via entitlements (Admins/Editors/Viewers), `grafana-oidc` ESO secret, local admin retained for break-glass. |
| In-cluster DNS | Default Talos CoreDNS | ✅ **Split-horizon forward** — `home-0ps.com:53 { forward . 10.3.3.1 }` added so in-cluster back-channels resolve internal hostnames. Live + in terraform (`8b3af1f`), **not applied**. |
| CryptPad | P1 live (Running 1/1, both hostnames 200) | ✗ **Spun down** 2026-05-19 — partial cleanup (see Hygiene). |
| Flux DAG | 15 Kustomizations (incl. cryptpad) | 14 Kustomizations — `cryptpad` removed, `authentik` added. |
| Object storage | wallabag bespoke S3 module | Reusable `terraform/modules/object-storage/` (R2 default) + `terraform/dev/authentik-object-storage/` (bucket `dev-authentik-e53522c0`). |
| CNPG storage | local-path (noted as DR risk) | Unchanged (still local-path) — but **decision made** to migrate to static iSCSI zvols + VolumeSnapshots (`storage-strategy-decision.md`). New S-tier below. |
| Alertmanager | ❌ No channels (O-7) | ✅ Slack `slack-critical`/`slack-warning` receivers, route tree, inhibit rules, `defaultRules.create: true`. |
| Certs | wildcard on `letsencrypt-STAGING` | wildcard on `letsencrypt-PRODUCTION` (C-2 closed). |
| Docs | + observability/self-deploy/thoth | + `storage-strategy-decision.md`, `gpu-sharing-decision.md`, `authentik-sso-implementation-handoff.md` (now marked ✅ complete). |

---

## Section 2 — Live Cluster Snapshot (2026-05-20)

```
Nodes:      6 Ready — cp-{200,201,202}, node-{203,204,205} — Talos v1.13.0 / k8s v1.35.0 / containerd 2.2.3 / kernel 6.18.24 — 22d
Flux:       14/14 Kustomizations Ready  ·  17/17 HelmReleases Ready
Certs:      wildcard-tls Ready (issuer: letsencrypt-PRODUCTION) · trust-manager, barman-cloud-{client,server}, op-connect-tls Ready
Workloads:  no pods outside Running/Completed
PVCs:       authentik (3×5Gi + 3×2Gi-wal local-path)  ·  freshrss (1×2Gi iscsi app + 3×5Gi + 3×2Gi-wal local-path)
            monitoring (alertmgr 5Gi + grafana 5Gi + prom 50Gi + tempo 30Gi, all iscsi)
Operators:  cert-manager, trust-manager, cnpg, democratic-csi (×2), external-dns, external-secrets, kyverno,
            onepassword-connect, prometheus-operator, renovate, tailscale-operator, authentik
```

Notable:

- **Every CNPG PVC is `local-path`** (authentik + freshrss). The only `iscsi` PVCs are the freshrss *app* volume and the four monitoring volumes. This is the gap the new S-tier addresses.
- **`mariadb-operator` / `redis-operator` stayed gone** (removed in the 2026-05-14 hygiene pass). No idle operators now except none.
- Wildcard cert is **production** issuer — no browser warnings on dev hosts.
- CoreDNS live ConfigMap carries the manual split-horizon block; a rebuild *without* applying `8b3af1f` would revert it.

---

## Section 3 — Open Items Punch List

Grouped by tier. Each item: **ID · what · status · location · next action.**

### CRITICAL — correctness / data integrity

| ID | Item | Status | Location | Next action |
| --- | --- | --- | --- | --- |
| ~~C-2~~ | ~~Wildcard cert on staging~~ | ✅ Done 2026-05-16 — `letsencrypt-production` | `_lib/networking/gateway/tls.yaml` | — |

(No open CRITICAL items.)

### HIGH — security hardening

| ID | Item | Status | Location | Next action |
| --- | --- | --- | --- | --- |
| ~~H-1~~ | ~~Kyverno Audit + ns labeling~~ | ✅ Done 2026-05-15 | — | — |
| H-2 | Cilium NetworkPolicies | ✅ Live for all running apps (freshrss + authentik) | `_lib/security/cilium-network-policies/{freshrss-*,authentik-*}.yaml` | Default-deny + app-allow + cnpg-allow per app, all namespace-label-scoped. **Follow-up:** the 2 `cryptpad-*` CCNPs are now orphaned (cryptpad gone) → delete (see Hygiene). Tighten world:443 egress to `toFQDNs` once L7 DNS policy is on. |
| H-3 | Falco | ❌ Disabled | `_lib/controllers/kustomization.yaml` (`#  - ./falco`) + `_lib/security/kustomization.yaml` (`#- ./falco-rules`) | `_lib/controllers/falco/` is populated (HelmRelease `8.0.0`, Talos modern_ebpf). `falco-rules/` has only an empty kustomization. Uncomment both, verify eBPF driver loads on Talos, confirm Prometheus scrapes the ServiceMonitor. |
| H-4 | ResourceQuotas + LimitRanges | ❌ Not started (grep: NONE in `_lib`/`global`) | per-app `base/` | Add `ResourceQuota` + `LimitRange` to each app namespace `base/`. Seed from `kube dev top pod -n <ns>` (Prometheus now has 18d history). Pairs with R-1. |
| H-5 | Trivy operator | ❌ Empty dir | `_lib/security/trivy/` (empty) + `_lib/security/kustomization.yaml` (`#- ./trivy`) | Populate with trivy-operator HelmRelease, uncomment. Wire reports → Grafana/Prometheus. |

### MEDIUM — resilience

| ID | Item | Status | Next action |
| --- | --- | --- | --- |
| R-1 | PodDisruptionBudgets | ❌ Zero (grep: NONE) | Add `policy/v1 PodDisruptionBudget` (`maxUnavailable: 1`) to `_lib/applications/freshrss/base/`. Let CNPG manage its own DB-pod disruption — don't hand-roll a PDB over CNPG pods. Verify with `--dry-run=server` drain. |
| R-3 | HPA | ⏸️ Deferred | Stateful single-replica apps; no candidate until Thoth's BFF. |
| R-7 | `terminationGracePeriodSeconds` | ⚠️ Not set (grep: NONE in `_lib/applications`) | Set 30–60s on `_lib/applications/freshrss/base/deployment.yaml` so PHP-FPM drains before SIGKILL. |

### Observability follow-ups

| ID | Item | Status | Next action |
| --- | --- | --- | --- |
| O-4 | K8s Warning events → Loki | ❌ | Add `loki.source.kubernetes_events` to `_lib/observability/alloy/configmap.yaml`. Check Alloy SA has `events {get,list,watch}` first. Highest ROI observability add. |
| O-5 | Cilium Gateway hardening | ❌ | On exposed HTTPRoutes (grafana, freshrss, authentik): strip `Server`/`X-Powered-By`, body-size limits, rate limiting via L7 CCNP / CiliumEnvoyConfig. |
| O-6 | Periodic posture scans | ❌ | `popeye` + `kubescape` CronJobs (daily, low-priority, `Forbid`) → stdout → Loki. |
| ~~O-7~~ | ~~Alertmanager routing~~ | ✅ Done (`67fcd52`) | Slack `slack-critical`/`slack-warning` receivers + route tree + inhibit rules + `defaultRules.create: true` in `_lib/observability/kube-prometheus-stack/helmrelease.yaml`. **Follow-up:** add app-specific rules (cert expiry, PVC near-full, CNPG not-healthy) + optional ntfy/email. |
| O-8 | Default-deny CCNP | 🟡 Per-app default-deny landed | `*-default-deny.yaml` exists for freshrss + authentik. No cluster-wide default-deny CCNP — add one if you want fail-closed for unlabeled namespaces. |
| O-9 | App-level dashboards/alerts | ❌ | FreshRSS, Authentik — once each app exposes metrics (Authentik chart can ship a ServiceMonitor; currently `serviceMonitor.enabled: false`). |

### Storage migration (NEW tier — from `storage-strategy-decision.md`)

| ID | Item | Status | Location | Next action |
| --- | --- | --- | --- | --- |
| S-1 | Snapshot infrastructure | ❌ Absent (grep: no VolumeSnapshot/snapshotter) | `global/crds/`, `_lib/storage/freenas-csi/` | Add `external-snapshotter` CRDs (→ `global/crds/`), snapshot-controller (→ `storage` layer), enable the democratic-csi snapshotter sidecar, create `VolumeSnapshotClass freenas-iscsi-snapclass`. Verify a manual snapshot of an existing iscsi PVC. **Blocks S-2 backups + S-3.** |
| S-2 | CNPG → single-instance static iSCSI zvol | ❌ Not started | `_lib/applications/{authentik,freshrss}/overlays/dev/` | Pre-create zvols (`dev-{authentik,freshrss}-db`) + static `Retain` PVs; CNPG `instances: 1`, drop `walStorage`, `storage.pvcTemplate.volumeName` → static PV. Migrate data via `bootstrap.pg_basebackup` (no S3). **Verify** `pvcTemplate.volumeName` honored by operator `0.27.0` on a throwaway cluster first. |
| S-3 | Retire R2/S3 from CNPG path | ❌ Not started | `_lib/applications/authentik/overlays/dev/ob-archiver.enc.yaml`, `terraform/dev/{authentik-object-storage,wallabag-s3-backup}/` | After S-2 + VolumeSnapshot backups verified: drop Authentik Barman/R2 ObjectStore; `terraform destroy` wallabag S3 (dead); destroy Authentik R2 bucket (lifecycle rule needs manual dashboard cleanup). |
| S-4 | iscsi StorageClass reclaim default | ⚠️ `Delete` | `_clusters/dev/config/cluster-configs.yaml:19` (`RECLAIM_POLICY: "Delete"`) | Flip to `Retain` so accidental dynamic iscsi volumes survive PVC deletion. |
| S-5 | freshrss CNPG has no backup | ⚠️ Gap | `_lib/applications/freshrss/overlays/dev/database.yaml` | Resolved naturally by S-2 (VolumeSnapshot ScheduledBackup). Until then freshrss DB is unprotected. |

### Hygiene / cleanup

| Item | Location | Action |
| --- | --- | --- |
| **CryptPad partial removal** | `_lib/applications/cryptpad/` (full tree); `_clusters/dev/config/cluster-configs.yaml:26-29` (4 `CRYPTPAD_*` keys); `_lib/security/cilium-network-policies/cryptpad-{default-deny,allow}.yaml` | Finish the spin-down: delete (or archive to `_docs/archive/cryptpad/` like wallabag) the manifest tree, the 4 config keys, and the 2 orphaned CCNPs. Confirm before destroying the `dev-cryptpad-data-pvc` TrueNAS zvol. |
| Placeholder cluster | `_clusters/production/` | Leave until prod promotion (stub). |
| Authentik handoff doc | `_docs/authentik-sso-implementation-handoff.md` | ✅ Marked complete 2026-05-20 (banner added) — historical record now, not a live task list. |

### Terraform / IaC

| ID | Item | Status | Note |
| --- | --- | --- | --- |
| TF-CoreDNS | Apply CoreDNS split-horizon inlineManifest | ⚠️ Committed (`8b3af1f`), not applied | `terraform/dev/talos-pve-v3.1.0/talos.tf`. Live cluster runs the manual edit; a rebuild without applying reverts the DNS fix. Run `/terraform-plan` → `/terraform-apply` to close the drift (interactive 1P auth). |
| R1 | Collapse `pve.tf` cp/worker duplication | ❌ | State-breaking now (cluster provisioned). Batch with next reprovision or `terraform state mv`. |
| R2 | Extract shared Talos machine config | ❌ | Worker still lacks CP-only PSA exemptions; drift risk. Batch with R1. |
| R5 | Worker memory typo `8092` | ⚠️ Module fixed, root not | `terraform/dev/variables.tf` + `terraform.tfvars` still carry `8092`; tfvars override makes it a live no-op. Tidy next tfvars edit. |
| TF-wallabag | Destroy dead wallabag S3 stack | ❌ | `terraform/dev/wallabag-s3-backup/` — app gone, bucket + IAM orphaned. (Folded into S-3.) |

### Manual / non-GitOps

| Item | Status | Note |
| --- | --- | --- |
| Beelink S13 BIOS power-loss = "Power On" | ❓ Unverified | `self-deployment-best-practices.md` §7 — pairs with Proxmox HA for power-blip self-recovery. |
| system-upgrade-controller for Talos | ⏸️ Hack-only | `_hack/scripts/upgrade.sh` + `_hack/yaml/system-upgrade-controller.yaml` exist; not deployed via Flux. NICE-TO-HAVE: formalize into `_lib/controllers/`. |
| SSO public exposure (Phase 4) | ⏸️ Not started | Cloudflare Tunnel + forward-auth outposts for public hostnames. Cloudflare WAF terraform (`terraform/dev/cloudflare-waf/`) not built. |

---

## Section 4 — Thoth (unified knowledge app) & future apps — Status

**Thoth** still **pre-decision** — `_docs/thoth-knowledge-app-decision.md`, 9 open research questions; anchor for the Istio Ambient service-mesh decision. No build commitment. Net-new infra it implies: MinIO, Meilisearch, NATS, Ollama, Istio Ambient, optional GPU node. Note: the new storage strategy (local CSI snapshots over object storage) intersects Thoth's "DR for MinIO-backed notes" question — revisit that question against `storage-strategy-decision.md`.

**Homer** — plan ready (`_docs/homer-implementation-plan.md`), **not started**. Stateless `b4bz/homer`, ConfigMap-driven, internal `dev.int.homer`. Lowest-risk app remaining; good landing page now SSO + services are live.

**GPU sharing** — pre-decision doc `_docs/gpu-sharing-decision.md` (recommends single-node VFIO passthrough on HP Slim S01).

---

## Section 5 — Suggested Next Sprint

In order, cut at natural stopping points:

1. **Homer PR1** — base deploy, internal `dev.int.homer`. Plan ready; no DB/PVC/secrets.
2. **Hygiene bundle** — finish CryptPad removal (manifests + 4 config keys + 2 orphaned CCNPs); apply the CoreDNS terraform (`8b3af1f`) to close the live-vs-IaC drift.
3. **H-4 + R-1 + R-7** — ResourceQuota/LimitRange + PodDisruptionBudget + terminationGracePeriod for freshrss (one namespace, one PR).
4. **H-3** — enable Falco; verify eBPF on Talos + ServiceMonitor scrape.
5. **O-4** — K8s Warning events → Loki (check Alloy RBAC first). Highest observability ROI.
6. **Storage migration (S-tier) — its own sprint.** S-1 snapshot infra → S-4 reclaim fix → S-2 freshrss (lower stakes) → S-2 authentik → S-3 retire R2/S3. Substantial; don't bolt onto the above.
7. **H-5** (Trivy), **O-5/O-6** (gateway hardening, posture scans), **O-9** (app dashboards; flip Authentik `serviceMonitor.enabled`).
8. (Parallel, low-priority) Terraform R1/R2/R5 batch; BIOS power-loss check; SSO public-exposure phase.

---

## Section 6 — Files Referenced

| File | Why it matters |
| --- | --- |
| `_clusters/dev/cluster.yaml` | 14-Kustomization DAG; `authentik` added, `cryptpad` removed |
| `_clusters/dev/config/cluster-configs.yaml` | `cluster-config` ConfigMap; `RECLAIM_POLICY: Delete` (S-4); 4 stale `CRYPTPAD_*` keys (Hygiene) |
| `_lib/applications/authentik/` | Live IdP — base (ESO, httproute) + overlay (CNPG, R2 ObjectStore) |
| `_lib/applications/freshrss/{base,overlays/dev}/` | R-1/R-7 target; static iscsi app PV pattern (template for S-2); DB has no backup (S-5) |
| `_lib/applications/cryptpad/` | Orphaned after spin-down (Hygiene) |
| `_lib/observability/kube-prometheus-stack/helmrelease.yaml` | Grafana OIDC; Alertmanager Slack routing (O-7 done) |
| `_lib/security/kustomization.yaml` | `cilium-network-policies` + `kyverno-policies` on; `falco-rules`, `trivy` commented (H-3/H-5) |
| `_lib/controllers/kustomization.yaml` | `authentik` on; `falco` commented (H-3) |
| `_lib/security/cilium-network-policies/` | freshrss + authentik CCNPs live; cryptpad CCNPs orphaned |
| `_lib/storage/freenas-csi/helmrelease.yaml` | democratic-csi `0.15.0`; snapshotter sidecar to enable (S-1) |
| `terraform/dev/talos-pve-v3.1.0/talos.tf` | CoreDNS inlineManifest (`8b3af1f`) — committed, not applied (TF-CoreDNS) |
| `terraform/dev/{authentik-object-storage,wallabag-s3-backup}/` | R2/S3 stacks to retire (S-3) |
| `_docs/storage-strategy-decision.md` | NEW — single-instance CNPG on static iscsi + VolumeSnapshots; R2/S3 exit (S-tier) |
| `_docs/object-storage-r2-vs-s3-decision.md` | Superseded for the CNPG backup path by the storage-strategy doc |
| `_docs/authentik-sso-implementation-handoff.md` | ✅ Complete — historical SSO implementation record |
| `_docs/homer-implementation-plan.md` | Next-app plan (ready) |
| `_docs/thoth-knowledge-app-decision.md` | Anchor-app design + mesh decision; 9 open questions |
| `_docs/home-0ps-review-2026-05-11.md` | Prior review — superseded by this one |
