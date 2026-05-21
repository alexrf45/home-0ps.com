# home-0ps.com Review — 2026-05-20

> Generated: 2026-05-20 (regenerated — supersedes the earlier same-day pass, which predated the Homer deploy)
> Scope: Status update against `home-0ps-review-2026-05-11.md`, plus `authentik-sso-implementation-handoff.md`, `storage-strategy-decision.md`, `object-storage-r2-vs-s3-decision.md`, `homer-implementation-plan.md`, `self-deployment-best-practices.md`, `thoth-knowledge-app-decision.md`. Live `memphis` dev cluster surveyed.
> Trigger: Periodic review (`/lab-review`). 15 commits since 2026-05-11; headline = Authentik SSO + Grafana OIDC landed and verified; **Homer dashboard now live and CryptPad spin-down fully cleaned up** (commit `cb18de6`).

---

## Executive Summary

The lab is stable and has closed out the two trailing items from the earlier same-day pass. The `memphis` dev cluster is healthy — 6 nodes (3 cp + 3 worker, Talos `v1.13.0`, k8s `v1.35.0`, 22d old), **all 15 Flux Kustomizations Ready**, **17/17 HelmReleases Ready**, no pods outside Running/Completed, all 5 certs Ready (wildcard on `letsencrypt-production`).

**Headline change since 2026-05-11:** **Authentik SSO is live and Grafana OIDC works end-to-end** (verified 2026-05-20). Authentik runs as its own top-level Flux Kustomization (chart `2026.2.3`), CNPG-backed, R2 backup wired, internal at `dev.int.auth.home-0ps.com`.

**Closed since the earlier 2026-05-20 pass (commit `cb18de6`):**

- **Homer dashboard is live** — stateless `b4bz/homer:v26.4.2`, own Flux Kustomization (`homer`, 21h old, Ready), 1/1 Running, internal `dev.int.homer.home-0ps.com`, no DB/PVC/secrets. First app shipped with PSA `restricted` *enforce* + per-container resource limits. (Sprint item #1 — done.)
- **CryptPad spin-down fully cleaned up** — manifest tree archived to `_docs/archive/cryptpad/`, the 4 `CRYPTPAD_*` config keys removed, the 2 orphaned `cryptpad-*` CCNPs deleted. `grep cryptpad _lib _clusters terraform` is now clean. (Hygiene item — done.)

**Other deltas since 2026-05-11** (carried from the earlier pass):

- **CoreDNS split-horizon fix** (`8b3af1f`) — in-cluster `*.home-0ps.com` resolves via UniFi; unblocked Grafana OIDC's back-channel. Live edit + terraform committed, **still not applied**.
- **Object-storage module** (`1c2eee2`) + Authentik R2 bucket provisioned.
- **CNPG CCNP** fix (`9c099d9`) — operator → instance-manager ingress on 8000.
- **Wildcard cert** is now `letsencrypt-production` (C-2 closed, 2026-05-16); SANs now carry `dev.int.homer`, cryptpad SANs removed.
- **Decision doc** `storage-strategy-decision.md` — single-instance CNPG on static iSCSI zvols + CSI VolumeSnapshots, exit R2/S3. **Decided, not built.**

**Still open and not moving:** the security-hardening tier — Falco (H-3), ResourceQuotas/LimitRanges (H-4), Trivy (H-5) — unchanged since the last three reviews. Resilience gaps persist: zero PodDisruptionBudgets (R-1), no `terminationGracePeriodSeconds` on freshrss (R-7). Storage migration S-tier (S-1…S-5) decided but not started.

**Recommended next sprint:** **resilience/hardening bundle for freshrss** (H-4 + R-1 + R-7, one namespace one PR), then **Falco** (H-3), then **K8s events → Loki** (O-4). Treat the storage migration (S-tier) as its own dedicated sprint. Homer RO-rootfs hardening (new HM-1) is a small follow-up. See §5.

---

## Section 1 — What Changed Since 2026-05-11

| Area           | 2026-05-11 state                          | 2026-05-20 state                                                                                                                                                                                       |
| -------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Identity / SSO | ❌ None                                   | ✅ **Authentik live** — own Flux Kustomization, chart `2026.2.3`, CNPG-backed (3×local-path), Barman→R2 backup, internal `dev.int.auth.home-0ps.com`. Redis-less (Postgres is broker+cache in 2026.x). |
| Grafana auth   | Local admin only                          | ✅ **OIDC via Authentik** — `auth.generic_oauth`, role mapping via entitlements (Admins/Editors/Viewers), `grafana-oidc` ESO secret, local admin retained for break-glass.                             |
| Dashboard app  | ❌ None                                   | ✅ **Homer live** — `b4bz/homer:v26.4.2`, own `homer` Flux Kustomization, stateless, internal `dev.int.homer.home-0ps.com`, PSA `restricted` enforce, per-container limits.                            |
| In-cluster DNS | Default Talos CoreDNS                     | ✅ **Split-horizon forward** — `home-0ps.com:53 { forward . 10.3.3.1 }` so in-cluster back-channels resolve internal hostnames. Live + in terraform (`8b3af1f`), **not applied**.                      |
| CryptPad       | P1 live (Running 1/1, both hostnames 200) | ✅ **Spun down + fully cleaned** — manifests archived, config keys + CCNPs removed (`cb18de6`).                                                                                                        |
| Flux DAG       | 15 Kustomizations (incl. cryptpad)        | 15 Kustomizations — `cryptpad` removed; `authentik` + `homer` added (+`flux-system` bootstrap = 15 live).                                                                                              |
| Object storage | wallabag bespoke S3 module                | Reusable `terraform/modules/object-storage/` (R2 default) + `terraform/dev/authentik-object-storage/` (bucket `dev-authentik-e53522c0`).                                                               |
| CNPG storage   | local-path (noted as DR risk)             | Unchanged (still local-path) — but **decision made** to migrate to static iSCSI zvols + VolumeSnapshots (`storage-strategy-decision.md`). S-tier below.                                                |
| Alertmanager   | ❌ No channels (O-7)                      | ✅ Slack `slack-critical`/`slack-warning` receivers, route tree, inhibit rules, `defaultRules.create: true`.                                                                                           |
| Certs          | wildcard on `letsencrypt-STAGING`         | wildcard on `letsencrypt-PRODUCTION` (C-2 closed); SANs `dev.int.{auth,grafana,homer,freshrss}`.                                                                                                       |
| Docs           | + observability/self-deploy/thoth         | + `storage-strategy-decision.md`, `gpu-sharing-decision.md`, `authentik-sso-implementation-handoff.md` (✅ complete).                                                                                  |

---

## Section 2 — Live Cluster Snapshot (2026-05-20, rev `cb18de6`)

```
Nodes:      6 Ready — cp-{200,201,202}, node-{203,204,205} — Talos v1.13.0 / k8s v1.35.0 / containerd 2.2.3 / kernel 6.18.24 — 22d
Flux:       15/15 Kustomizations Ready  ·  17/17 HelmReleases Ready  (all at dev@cb18de6)
Certs:      wildcard-tls Ready (issuer: letsencrypt-PRODUCTION) · trust-manager, barman-cloud-{client,server}, op-connect-tls Ready
Workloads:  no pods outside Running/Completed  ·  homer 1/1 Running 21h, 0 restarts
PVCs:       authentik (3×5Gi + 3×2Gi-wal local-path)  ·  freshrss (1×2Gi iscsi app + 3×5Gi + 3×2Gi-wal local-path)
            monitoring (alertmgr 5Gi + grafana 5Gi + prom 50Gi + tempo 30Gi, all iscsi)  ·  homer: none (stateless)
Operators:  cert-manager, trust-manager, cnpg, democratic-csi (×2), external-dns, external-secrets, kyverno,
            onepassword-connect, prometheus-operator, renovate, tailscale-operator, authentik
```

Notable:

- **Every CNPG PVC is `local-path`** (authentik + freshrss). The only `iscsi` PVCs are the freshrss _app_ volume and the four monitoring volumes. This is the gap the S-tier addresses.
- **No idle operators** — mariadb/redis operators stayed gone (removed in the 2026-05-14 hygiene pass).
- Wildcard cert is **production** issuer — no browser warnings on dev hosts.
- CoreDNS live ConfigMap carries the manual split-horizon block; a rebuild _without_ applying `8b3af1f` would revert it (TF-CoreDNS — could not verify a terraform apply landed; treat as still-open).
- Homer is the **first app with `pod-security.kubernetes.io/enforce: restricted`** at the namespace — a good precedent to backfill onto freshrss/authentik.

---

## Section 3 — Open Items Punch List

Grouped by tier. Each item: **ID · what · status · location · next action.**

### CRITICAL — correctness / data integrity

| ID      | Item                         | Status                                        | Location                           | Next action |
| ------- | ---------------------------- | --------------------------------------------- | ---------------------------------- | ----------- |
| ~~C-2~~ | ~~Wildcard cert on staging~~ | ✅ Done 2026-05-16 — `letsencrypt-production` | `_lib/networking/gateway/tls.yaml` | —           |

(No open CRITICAL items.)

### HIGH — security hardening

| ID      | Item                            | Status                                              | Location                                                                                                         | Next action                                                                                                                                                                                                  |
| ------- | ------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ~~H-1~~ | ~~Kyverno Audit + ns labeling~~ | ✅ Done 2026-05-15                                  | —                                                                                                                | —                                                                                                                                                                                                          |
| H-2     | Cilium NetworkPolicies          | ✅ Live for all running apps (freshrss + authentik + homer) | `_lib/security/cilium-network-policies/{freshrss-*,authentik-*,homer-*}.yaml`                            | Default-deny + app-allow per app, namespace-label-scoped; orphaned cryptpad CCNPs deleted (`cb18de6`). **Follow-up:** tighten world:443 egress to `toFQDNs` once L7 DNS policy is on.                       |
| H-3     | Falco                           | ❌ Disabled                                         | `_lib/controllers/kustomization.yaml:8` (`#  - ./falco`) + `_lib/security/kustomization.yaml:6` (`#- ./falco-rules`) | `_lib/controllers/falco/` is populated (HelmRelease `8.0.0`, Talos modern_ebpf). `falco-rules/` has only an empty kustomization. Uncomment both, verify eBPF driver loads on Talos, confirm Prometheus scrapes the ServiceMonitor. |
| H-4     | ResourceQuotas + LimitRanges    | ❌ Not started (grep: NONE in `_lib`/`global`)      | per-app `base/`                                                                                                  | Add `ResourceQuota` + `LimitRange` to each app namespace `base/`. Seed from `kube dev top pod -n <ns>` (Prometheus now has 18d history). Note: homer already sets per-container limits but lacks a namespace LimitRange. Pairs with R-1. |
| H-5     | Trivy operator                  | ❌ Empty dir                                        | `_lib/security/trivy/` (empty) + `_lib/security/kustomization.yaml:8` (`#- ./trivy`)                             | Populate with trivy-operator HelmRelease, uncomment. Wire reports → Grafana/Prometheus.                                                                                                                    |

### MEDIUM — resilience

| ID  | Item                            | Status                                         | Next action                                                                                                                                                                                                              |
| --- | ------------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R-1 | PodDisruptionBudgets            | ❌ Zero (grep: NONE)                           | Add `policy/v1 PodDisruptionBudget` (`maxUnavailable: 1`) to `_lib/applications/freshrss/base/`. Let CNPG manage its own DB-pod disruption — don't hand-roll a PDB over CNPG pods. Homer is stateless single-replica (Recreate) → low value, skip. Verify with `--dry-run=server` drain. |
| R-3 | HPA                             | ⏸️ Deferred                                    | Stateful single-replica apps; no candidate until Thoth's BFF.                                                                                                                                                            |
| R-7 | `terminationGracePeriodSeconds` | ⚠️ Not set (grep: NONE in `_lib/applications`) | Set 30–60s on `_lib/applications/freshrss/base/deployment.yaml` so PHP-FPM drains before SIGKILL.                                                                                                                        |

### Observability follow-ups

| ID      | Item                        | Status                         | Next action                                                                                                                                                                                                                                                                             |
| ------- | --------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| O-4     | K8s Warning events → Loki   | ❌                             | Add `loki.source.kubernetes_events` to `_lib/observability/alloy/configmap.yaml`. Check Alloy SA has `events {get,list,watch}` first. Highest ROI observability add.                                                                                                                    |
| O-5     | Cilium Gateway hardening    | ❌                             | On exposed HTTPRoutes (grafana, freshrss, authentik, homer): strip `Server`/`X-Powered-By`, body-size limits, rate limiting via L7 CCNP / CiliumEnvoyConfig.                                                                                                                            |
| O-6     | Periodic posture scans      | ❌                             | `popeye` + `kubescape` CronJobs (daily, low-priority, `Forbid`) → stdout → Loki.                                                                                                                                                                                                        |
| ~~O-7~~ | ~~Alertmanager routing~~    | ✅ Done (`67fcd52`)            | Slack `slack-critical`/`slack-warning` receivers + route tree + inhibit rules + `defaultRules.create: true` in `_lib/observability/kube-prometheus-stack/helmrelease.yaml`. **Follow-up:** add app-specific rules (cert expiry, PVC near-full, CNPG not-healthy) + optional ntfy/email. |
| O-8     | Default-deny CCNP           | 🟡 Per-app default-deny landed | `*-default-deny.yaml` exists for freshrss + authentik + homer. No cluster-wide default-deny CCNP — add one if you want fail-closed for unlabeled namespaces.                                                                                                                            |
| O-9     | App-level dashboards/alerts | ❌                             | FreshRSS, Authentik — once each app exposes metrics (Authentik chart can ship a ServiceMonitor; currently `serviceMonitor.enabled: false`). Homer has no metrics endpoint (static dashboard) — skip.                                                                                    |

### Homer follow-ups (NEW)

| ID   | Item                          | Status                  | Location                                          | Next action                                                                                                                                                                            |
| ---- | ----------------------------- | ----------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| HM-1 | Homer read-only root FS       | ⚠️ `readOnlyRootFilesystem: false` (deliberate PR1) | `_lib/applications/homer/base/deployment.yaml:51` | Entrypoint seeds theme assets into `/www/assets` on boot. Enumerate writable paths on the live pod, mount them as `emptyDir`, then flip to `readOnlyRootFilesystem: true`. |
| HM-2 | Homer service-tile content    | ❓ Verify                | `_lib/applications/homer/base/configmap.yaml`     | Confirm `config.yml` lists the live internal hosts (grafana, freshrss, authentik) so the dashboard is actually useful; update as apps land.                                            |

### Storage migration (S-tier — from `storage-strategy-decision.md`)

| ID  | Item                                     | Status                                          | Location                                                                                                                        | Next action                                                                                                                                                                                                                                                                                                      |
| --- | ---------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S-1 | Snapshot infrastructure                  | ❌ Absent (grep: no VolumeSnapshot/snapshotter) | `global/crds/`, `_lib/storage/freenas-csi/`                                                                                     | Add `external-snapshotter` CRDs (→ `global/crds/`), snapshot-controller (→ `storage` layer), enable the democratic-csi snapshotter sidecar, create `VolumeSnapshotClass freenas-iscsi-snapclass`. Verify a manual snapshot of an existing iscsi PVC. **Blocks S-2 backups + S-3.**                               |
| S-2 | CNPG → single-instance static iSCSI zvol | ❌ Not started                                  | `_lib/applications/{authentik,freshrss}/overlays/dev/`                                                                          | Pre-create zvols (`dev-{authentik,freshrss}-db`) + static `Retain` PVs; CNPG `instances: 1`, drop `walStorage`, `storage.pvcTemplate.volumeName` → static PV. Migrate data via `bootstrap.pg_basebackup` (no S3). **Verify** `pvcTemplate.volumeName` honored by operator `0.27.0` on a throwaway cluster first. |
| S-3 | Retire R2/S3 from CNPG path              | ❌ Not started                                  | `_lib/applications/authentik/overlays/dev/ob-archiver.enc.yaml`, `terraform/dev/{authentik-object-storage,wallabag-s3-backup}/` | After S-2 + VolumeSnapshot backups verified: drop Authentik Barman/R2 ObjectStore; `terraform destroy` wallabag S3 (dead); destroy Authentik R2 bucket (lifecycle rule needs manual dashboard cleanup).                                                                                                          |
| S-4 | iscsi StorageClass reclaim default       | ⚠️ `Delete`                                     | `_clusters/dev/config/cluster-configs.yaml:19` (`RECLAIM_POLICY: "Delete"`)                                                     | Flip to `Retain` so accidental dynamic iscsi volumes survive PVC deletion.                                                                                                                                                                                                                                       |
| S-5 | freshrss CNPG has no backup              | ⚠️ Gap                                          | `_lib/applications/freshrss/overlays/dev/database.yaml`                                                                         | Resolved naturally by S-2 (VolumeSnapshot ScheduledBackup). Until then freshrss DB is unprotected.                                                                                                                                                                                                               |

### Hygiene / cleanup

| Item                         | Location                                            | Action                                                                                                                                            |
| ---------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| ~~CryptPad partial removal~~ | ~~`_lib/applications/cryptpad/`; `CRYPTPAD_*` keys; cryptpad CCNPs~~ | ✅ Done 2026-05-20 (`cb18de6`) — tree archived to `_docs/archive/cryptpad/`, 4 config keys + 2 CCNPs removed. Confirm the `dev-cryptpad-data-pvc` TrueNAS zvol is destroyed (only manual step left). |
| Placeholder cluster          | `_clusters/production/`                              | Leave until prod promotion (stub).                                                                                                              |
| Authentik handoff doc        | `_docs/authentik-sso-implementation-handoff.md`     | ✅ Marked complete 2026-05-20 — historical record now, not a live task list.                                                                    |

### Terraform / IaC

| ID          | Item                                       | Status                                | Note                                                                                                                                                                                                               |
| ----------- | ------------------------------------------ | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| TF-CoreDNS  | Apply CoreDNS split-horizon inlineManifest | ⚠️ Committed (`8b3af1f`), apply unverified | `terraform/dev/talos-pve-v3.1.0/talos.tf`. Live cluster runs the manual edit; a rebuild without applying reverts the DNS fix. Run `/terraform-plan` → `/terraform-apply` to close the drift (interactive 1P auth). |
| R1          | Collapse `pve.tf` cp/worker duplication    | ❌                                    | State-breaking now (cluster provisioned). Batch with next reprovision or `terraform state mv`.                                                                                                                     |
| R2          | Extract shared Talos machine config        | ❌                                    | Worker still lacks CP-only PSA exemptions; drift risk. Batch with R1.                                                                                                                                              |
| R5          | Worker memory typo `8092`                  | ⚠️ Module fixed, root not             | `terraform/dev/variables.tf` + `terraform.tfvars` still carry `8092`; tfvars override makes it a live no-op. Tidy next tfvars edit.                                                                                |
| TF-wallabag | Destroy dead wallabag S3 stack             | ❌                                    | `terraform/dev/wallabag-s3-backup/` — app gone, bucket + IAM orphaned. (Folded into S-3.)                                                                                                                          |

### Manual / non-GitOps

| Item                                     | Status         | Note                                                                                                                                                     |
| ---------------------------------------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Beelink S13 BIOS power-loss = "Power On" | ❓ Unverified  | `self-deployment-best-practices.md` §7 — pairs with Proxmox HA for power-blip self-recovery.                                                             |
| system-upgrade-controller for Talos      | ⏸️ Hack-only   | `_hack/scripts/upgrade.sh` + `_hack/yaml/system-upgrade-controller.yaml` exist; not deployed via Flux. NICE-TO-HAVE: formalize into `_lib/controllers/`. |
| SSO public exposure (Phase 4)            | ⏸️ Not started | Cloudflare Tunnel + forward-auth outposts for public hostnames. Cloudflare WAF terraform (`terraform/dev/cloudflare-waf/`) not built.                    |
| CryptPad TrueNAS zvol                    | ❓ Verify      | `dev-cryptpad-data-pvc` zvol — confirm destroyed now that all manifests are gone (last CryptPad cleanup step).                                           |

---

## Section 4 — Thoth (unified knowledge app) & future apps — Status

**Thoth** still **pre-decision** — `_docs/thoth-knowledge-app-decision.md`, 9 open research questions; anchor for the Istio Ambient service-mesh decision. No build commitment. Net-new infra it implies: MinIO, Meilisearch, NATS, Ollama, Istio Ambient, optional GPU node. Note: the new storage strategy (local CSI snapshots over object storage) intersects Thoth's "DR for MinIO-backed notes" question — revisit that question against `storage-strategy-decision.md`.

**Homer** — ✅ **Live** (was the next-app candidate; shipped `cb18de6`). Internal `dev.int.homer.home-0ps.com`. Remaining polish tracked as HM-1 (RO-rootfs) and HM-2 (tile content). Good landing page now SSO + services are live.

**GPU sharing** — pre-decision doc `_docs/gpu-sharing-decision.md` (recommends single-node VFIO passthrough on HP Slim S01).

---

## Section 5 — Suggested Next Sprint

In order, cut at natural stopping points:

1. **H-4 + R-1 + R-7 (freshrss)** — ResourceQuota/LimitRange + PodDisruptionBudget + terminationGracePeriod, one namespace, one PR. Highest resilience ROI now that the easy apps are shipped.
2. **HM-1 + HM-2 (Homer polish)** — enumerate writable paths, flip to RO-rootfs; populate `config.yml` tiles. Small, low-risk.
3. **H-3** — enable Falco; verify eBPF on Talos + ServiceMonitor scrape.
4. **O-4** — K8s Warning events → Loki (check Alloy RBAC first). Highest observability ROI.
5. **Apply CoreDNS terraform (TF-CoreDNS)** — close the live-vs-IaC drift (`/terraform-plan` → `/terraform-apply`, interactive 1P auth).
6. **Storage migration (S-tier) — its own sprint.** S-1 snapshot infra → S-4 reclaim fix → S-2 freshrss (lower stakes) → S-2 authentik → S-3 retire R2/S3. Substantial; don't bolt onto the above.
7. **H-5** (Trivy), **O-5/O-6** (gateway hardening, posture scans), **O-9** (app dashboards; flip Authentik `serviceMonitor.enabled`).
8. (Parallel, low-priority) Terraform R1/R2/R5 batch; BIOS power-loss check; CryptPad zvol destroy; SSO public-exposure phase.

---

## Section 6 — Files Referenced

| File                                                           | Why it matters                                                                                  |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `_clusters/dev/cluster.yaml`                                   | 15-Kustomization DAG; `homer` added, `cryptpad` removed                                          |
| `_clusters/dev/config/cluster-configs.yaml`                    | `cluster-config` ConfigMap; `RECLAIM_POLICY: Delete` (S-4); `HOMER_*` keys; `CRYPTPAD_*` removed |
| `_lib/applications/homer/`                                     | New live app — base (deploy/svc/route/configmap/ns) + overlay; HM-1/HM-2 targets                |
| `_lib/applications/authentik/`                                 | Live IdP — base (ESO, httproute) + overlay (CNPG, R2 ObjectStore)                               |
| `_lib/applications/freshrss/{base,overlays/dev}/`              | R-1/R-7/H-4 target; static iscsi app PV pattern (template for S-2); DB has no backup (S-5)      |
| `_docs/archive/cryptpad/`                                      | Archived after spin-down (Hygiene ✅)                                                            |
| `_lib/observability/kube-prometheus-stack/helmrelease.yaml`    | Grafana OIDC; Alertmanager Slack routing (O-7 done)                                             |
| `_lib/security/kustomization.yaml`                             | `cilium-network-policies` + `kyverno-policies` on; `falco-rules`, `trivy` commented (H-3/H-5)   |
| `_lib/controllers/kustomization.yaml`                          | `authentik` on; `falco` commented (H-3)                                                         |
| `_lib/security/cilium-network-policies/`                       | freshrss + authentik + homer CCNPs live; cryptpad CCNPs removed                                 |
| `_lib/networking/gateway/tls.yaml`                             | wildcard `letsencrypt-production`; SANs `dev.int.{auth,grafana,homer,freshrss}`                 |
| `_lib/storage/freenas-csi/helmrelease.yaml`                    | democratic-csi `0.15.0`; snapshotter sidecar to enable (S-1)                                    |
| `terraform/dev/talos-pve-v3.1.0/talos.tf`                      | CoreDNS inlineManifest (`8b3af1f`) — committed, apply unverified (TF-CoreDNS)                   |
| `terraform/dev/{authentik-object-storage,wallabag-s3-backup}/` | R2/S3 stacks to retire (S-3)                                                                    |
| `_docs/storage-strategy-decision.md`                           | single-instance CNPG on static iscsi + VolumeSnapshots; R2/S3 exit (S-tier)                     |
| `_docs/homer-implementation-plan.md`                           | Homer plan — now ✅ shipped                                                                      |
| `_docs/thoth-knowledge-app-decision.md`                        | Anchor-app design + mesh decision; 9 open questions                                             |
| `_docs/home-0ps-review-2026-05-11.md`                          | Prior distinct review — superseded by this one                                                  |
