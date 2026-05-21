# Best practices & lessons learned — home-0ps

The patterns this lab has settled on, and the hard-won lessons behind them. Distilled from the dated reviews, the decision records, and Yunus Koçyiğit's *Self-Deployment for Software Developers* (reconciled against the lab's Talos + Flux + Cilium + CNPG + ESO stack — most of the book's single-server `k3s`/`nginx`/`ufw` advice is already solved by the distribution choices or replaced by a stronger primitive).

This is the doc to read before adding an app or changing infra. It's opinionated on purpose.

---

## 1. GitOps discipline

- **Layer with explicit `dependsOn`.** The Flux DAG in `_clusters/dev/cluster.yaml` is ordered cluster-config → crds → controllers → pki → ESO → secrets → networking → dns → storage → observability → security → apps. Each app is its **own top-level Kustomization** (no shared "applications" bucket) so one app's failure can't wedge the others.
- **Operators don't install their own CRDs.** Any operator whose CRs are Flux-reconciled sets `crds.enabled: false` (or the chart's equivalent); CRDs live in `global/crds/` (the `crds` layer, before controllers), version-pinned to the operator chart. This kills the kustomize-controller dry-run race when a CR and its CRD-installing chart share a Kustomization. Prefer upstream CRD-only subcharts (Renovate updates for free).
- **Parameterize via `cluster-config`.** Hostnames, versions, storage params live in `_clusters/dev/config/cluster-configs.yaml` and reach manifests through `postBuild.substituteFrom`. Watch the **substitution-scope trap**: an HTTPRoute in the app layer sees a var the `networking`-layer cert does not — so cert SANs are hardcoded while routes use `${VAR}`.
- **Always go through the `kubeop.sh` wrappers** (`kube`/`k9s-op`/`k8sop`) — the kubeconfig is fetched from 1Password on demand, not on disk. Raw `kubectl`/`flux`/`helm` target nothing. (talosctl is the only exception.)

## 2. Security & hardening

### Pod Security Standards
Homer is the precedent: namespace `pod-security.kubernetes.io/enforce: restricted` with a pod spec that satisfies it. Backfill `restricted` onto freshrss/authentik namespaces.

### securityContext — set `runAsUser` explicitly {#kyverno-securitycontext-mutation}
The Kyverno `add-default-securitycontext` policy mutates an **unset** `runAsUser` to `65534`. A pod-level `runAsUser` does **not** override it at the container level — set `runAsUser` explicitly on **every container** or the app runs as the wrong UID and can't read its own files.

### Permissions & writable paths — enumerate them all in one pass {#permissions--writable-paths}
When an image's entrypoint assumes root but you run it unprivileged, do **one** audit of *every* path it writes (run dirs, log dirs, cache dirs, config, data) — don't discover them one CrashLoop at a time. The reference implementation is FreshRSS ([apps/freshrss.md](../apps/freshrss.md#the-securitycontext-and-writable-paths-pattern)): a root init container with only `CHOWN`/`DAC_OVERRIDE`/`FOWNER` seeds config into `emptyDir`s and pre-`chown`s the data volume, then the main container runs as the app UID with all caps dropped. Talos `/tmp` is a capped `tmpfs` — use an explicit `emptyDir` (optionally `medium: Memory` + `sizeLimit`) for scratch.

### Network policies — default-deny per app
Each app ships `*-default-deny` + `*-allow` (+ `*-cnpg-allow` if it has a DB). Two non-obvious rules:
- **Gateway backends need `fromEntities: [ingress]`** — Cilium Gateway proxy→backend traffic carries the `reserved:ingress` identity; `host`/`remote-node` only covers kubelet probes.
- **CNPG instances need operator ingress on 8000** — every `*-cnpg-allow` must allow the `cloudnative-pg` operator (database ns) or fresh clusters hang at `1/N`.

### Log shippers run as root {#log-shippers-need-root}
`capabilities.add` lands in the *bounding* set only on non-root pods, so Alloy/Promtail-style shippers need `runAsUser: 0` to read `/var/log/pods`. Counter-intuitive but required.

## 3. Resilience

These are the standing gaps — the lab targets prod-ready posture but hasn't closed them. Priority order:

1. **PodDisruptionBudget + `terminationGracePeriodSeconds` on every stateful app.** There is **zero** PDB in the repo — a node drain (Talos upgrade) evicts the DB-backed pod with no in-flight protection. Add `policy/v1 PodDisruptionBudget` (`maxUnavailable: 1`) per app; let CNPG manage its own DB-pod disruption (use its primitives, not a hand-rolled PDB over CNPG pods). Bump grace to 30–120s so PHP-FPM finishes in-flight requests.
2. **ResourceQuota + LimitRange per app namespace.** Nothing is bounded today — one runaway pod can starve the cluster. Put them in `base/` (LimitRange defaults apply at admission); seed from `kube dev top pod -n <ns>` now that Prometheus has history. Start loose, tighten with 30 days of data.
3. **Probe audit.** Liveness + readiness on every app; liveness on a longer `initialDelaySeconds`. Don't reuse `pg_isready` as an app dependency probe — it doesn't check replication/WAL; let CNPG status drive that. `startupProbe` is overkill for anything that comes up in <30s.
4. **HA is a deliberate trade, not a default.** Per [ADR-0003](../decisions/0003-cnpg-local-snapshots.md), single-instance CNPG is the right call here — a 3-node quorum doesn't survive the lab's real failure domains (NAS, rack, house). Put durability in ZFS (RAID + snapshots), accept minutes of downtime on reschedule. Don't add HPA to stateful single-instance apps.

## 4. Secrets

- **Keep everything rotatable.** Never move a 1P-backed `ExternalSecret` field to a literal, even if it's non-sensitive — rotation flexibility is the point.
- **One 1P item → one ExternalSecret → one Secret**, even when it emits multiple key shapes (CNPG ignores extra keys). See [infra/secrets-pki.md](../infra/secrets-pki.md).
- **Claude writes plaintext, the operator encrypts.** Never re-encrypt SOPS/`.env` files without explicit confirmation.
- Rotated 1P values only matter for the *next* pod start; force a resync with the `force-sync` annotation when you need it now.

## 5. Storage & data

- **Durability belongs in the storage layer, not the app replica count.** ZFS RAID + snapshots beat N ephemeral local-path copies.
- **Static volumes over dynamic for anything you want to keep.** Pre-create the zvol, check a `Retain` PV+PVC into the overlay, pin with `volumeName` (the FreshRSS app-volume pattern). Flip the dynamic `iscsi` class default to `Retain` too (S-4).
- **CNPG bootstrap is one-shot/immutable.** To retry recovery: suspend Flux, delete the `Cluster` + instance PVCs, resume. CNPG doesn't GC instance PVCs on cluster deletion — that's what enables the soft-teardown / re-adopt loop. **Never** point `bootstrap.initdb` at a zvol that already holds PGDATA.
- **Snapshot infra before retiring the off-site backup** — don't delete the only copy before its replacement is proven (S-1 before S-3).

## 6. Observability — highest-ROI moves

- **Kubernetes Warning events → Loki is the single best low-effort add** (O-4). Add `loki.source.kubernetes_events` to Alloy — but verify the Alloy SA has `events {get,list,watch}` first (ship the RBAC in the same commit).
- **Offload logs off-cluster** so retention outlives the cluster (Loki on the bare-metal host over Tailscale).
- **Periodic posture scans** (`popeye`, `kubescape`) as low-priority CronJobs → Loki are a forcing function for the resilience gaps above — real ROI on a lab chasing prod posture.

## 7. Operations & DR

- **Write the recovery runbook when you build the thing, not after the outage.** Authentik's break-glass (`akadmin`, never federated) + R2 rotation + CNPG-restore steps existed before they were needed ([apps/authentik.md](../apps/authentik.md#recovery-and-day-2)).
- **Debugging discipline:** state the exact symptom, read the failing component's real config/logs, form a hypothesis with a verification step, *then* fix. Don't stack speculative fixes.
- **Manual one-offs still get documented.** e.g. Beelink S13 BIOS "AC Power Loss → Power On" (pairs with Proxmox HA for power-blip self-recovery) — verify on all 6 nodes.

## 8. What the reference book gets wrong for this lab

- **Single-node `k3s`** — the lab is Talos + 6 nodes *specifically* to learn HA primitives. Don't downscale.
- **Ansible / bash config management** — GitOps (Terraform + Flux + Renovate) replaces it; adopting Ansible would be a regression.
- **ufw + fail2ban** — Talos is a read-only OS with no SSH and a restricted kube API; its threat model is stricter.
- **`kubectl-ai` with write access** — never connect an LLM with cluster write to dev; read-only via a scoped SA only.

---

For the live punch list of what's open right now, see the newest [review](../reviews/home-0ps-review-2026-05-20.md) and the [journey](../journey.md).
