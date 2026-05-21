# The home-0ps lab journey

The narrative arc of the lab — what was built, in what order, why, and what each phase taught. For the *current* open-items punch list, read the newest [review](reviews/home-0ps-review-2026-05-20.md); for the patterns that came out of all this, read [guides/best-practices.md](guides/best-practices.md); for the big calls, the [decisions](decisions/0001-sso-authentik.md) (ADRs).

This doc is the "how did we get here" record. It's append-mostly — each phase is history.

---

## Phase 0 — Repo migration & structure (≈2026-04-02)

The starting point was a messy repo: duplicated controller definitions, an `infrastructure/` directory mixing concerns, inconsistent HelmRelease namespacing, gateway duplication, Renovate scanning stale paths. Seven structural issues in total.

**What landed:** the `_lib/` layout with a layered Flux DAG (`_clusters/dev/cluster.yaml`), each layer its own Kustomization with explicit `dependsOn`; a single parameterized gateway; `postBuild.substituteFrom` from a `cluster-config` ConfigMap.

**Lesson:** the layered-DAG + per-concern-Kustomization structure is the foundation everything else hangs off. Getting it right early made every later addition a small, isolated change.

## Phase 1 — Hardware relocation (2026-04-27)

The physical lab (6 Beelink mini-PCs, UniFi networking, Zimaboard NAS) moved locations. Same subnet (`192.168.20.0/24`), so no IP rework — but the cluster needed a fresh provision.

**What landed:** the structural migration was confirmed *complete* (all 7 issues resolved → migration review retired). A focused Terraform module audit (`talos-pve-v3.1.0`) produced refactor recommendations R1–R7; the cheap/safe ones (pinned `extraManifests`, cross-variable IP validation, magic-value externalization, `bootstrap.sh` removal) were done; the state-breaking ones (R1 cp/worker `for_each` collapse, R2 shared machine config) were deferred to the next reprovision. Wallabag's guaranteed-OOMKill resource limits were fixed.

**Lesson:** a fresh provision is the cheapest window for state-breaking Terraform refactors (no `terraform state mv`). The deferred R1/R2 are still waiting for that window.

## Phase 2 — Observability backbone (≈2026-05-11)

Stand up metrics/logs/traces *before* any service mesh, so the "before/after" of the mesh is felt later.

**What landed:** kube-prometheus-stack (Prometheus/Grafana/Alertmanager), Tempo, and Alloy shipping logs to an **off-cluster** Loki on the bare-metal host (`192.168.20.87`) over Tailscale. External scrape targets (TrueNAS, 1P Connect, Tailscale) wired. Kyverno flipped to Audit + namespace labeling; per-app Cilium NetworkPolicies began. Later: Alertmanager Slack routing + default rules. See [infra/observability.md](infra/observability.md).

**Lessons:** off-cluster logs decouple retention from cluster lifecycle. Log shippers need `runAsUser: 0` (the bounding-set gotcha). The single highest-ROI add — Kubernetes events → Loki — is *still* open (O-4).

## Phase 3 — App churn & the knowledge-tool hunt (2026-05-14 → 05-20)

A burst of spin-ups and spin-downs as the lab searched for the right personal-knowledge stack — the thread that ultimately points at the Thoth idea ([ADR-0005](decisions/0005-thoth-knowledge-app.md)). See [Retired apps](#retired-apps) for the retrospectives.

- **2026-05-14** — Wallabag spun down (→ planned Thoth unification).
- **2026-05-15** — Syncthing spun down (→ CryptPad for notes).
- **2026-05-16** — wildcard cert flipped to `letsencrypt-production`; reusable object-storage R2 module + Authentik bucket ([ADR-0002](decisions/0002-object-storage-r2.md)).
- **2026-05-19** — CryptPad removed; CoreDNS split-horizon forward; Grafana OIDC switched to entitlements.
- **2026-05-20** — the milestone day.

**Lesson:** the lab cycled through three knowledge tools in a week. That churn *is* the argument for stepping back and deciding the unified-app question deliberately rather than deploying-then-retiring — which is exactly what [ADR-0005](decisions/0005-thoth-knowledge-app.md) exists to force.

## Phase 4 — Identity & the dashboard (2026-05-20)

**What landed:** **Authentik SSO live and verified**, with **Grafana OIDC working end-to-end** — the per-app provider/application/entitlement pattern is now proven ([ADR-0001](decisions/0001-sso-authentik.md), [apps/authentik.md](apps/authentik.md)). **Homer** shipped as the landing-page dashboard — the first app with PSA `restricted` *enforce* and per-container limits ([apps/homer.md](apps/homer.md)). CryptPad cleanup finished. The storage-strategy decision ([ADR-0003](decisions/0003-cnpg-local-snapshots.md)) was made (single-instance CNPG on static iSCSI + CSI snapshots).

**Lessons:** the Grafana OIDC blocker turned out to be **DNS, not OIDC** — the in-cluster back-channel couldn't resolve the internal auth hostname until the CoreDNS split-horizon forward landed ([infra/dns.md](infra/dns.md)). Authentik 2026.x is Redis-less. Write the recovery runbook *with* the build.

## Where the lab is now

Stable: 6-node Talos cluster, all Flux Kustomizations + HelmReleases Ready, SSO + observability live, three live apps (Authentik, FreshRSS, Homer) + Grafana. The standing debt is the **resilience/hardening tier** (PDBs, quotas, Falco, Trivy) and the **storage migration** (S-tier) — both tracked in the newest review. Next deliberate steps live in [guides/best-practices.md §3](guides/best-practices.md#3-resilience) and the review's suggested sprint.

---

## Retired apps

Lifecycle retrospectives. The pattern across all three: each was a step in the hunt for a personal-knowledge stack, and each fed lessons into the Thoth decision.

### Wallabag (read-it-later) — retired 2026-05-14

- **Why deployed:** first real application; established the CNPG + Barman→S3 + ESO app template the lab still uses.
- **Why retired:** folded into the planned Thoth unification, not a failure.
- **What we learned:** it produced the reusable app shape (namespace + ExternalSecret + hardened Deployment + Service + HTTPRoute + CNPG overlay). It also surfaced the **missing-resource-limits → OOMKill** trap (caught at the 2026-04-27 review) and the **root-entrypoint vs non-root container** permission problem later solved cleanly in FreshRSS.
- **Cleanup completeness:** manifests archived to `_docs/archive/wallabag/`; the R2/S3 backup bucket was **intentionally retained** for restore — which means it's now an orphaned stack to destroy (tracked as S-3 / TF-wallabag). **Restorable** (recovery overlay still wired).

### Syncthing (file sync) — retired 2026-05-15

- **Why deployed:** bidirectional markdown-notes sync (the workflow the operator had used for years).
- **Why retired:** replaced by CryptPad for notes — *not* a 1:1 replacement (collaborative-doc app, not a sync engine).
- **What we learned:** the cleanup was the lesson — a **thorough teardown** (PVs `kubectl delete`d, TrueNAS zvols `zfs destroy`ed, iSCSI targets removed, data confirmed migrated out-of-band) in deliberate contrast to wallabag's retain-the-bucket approach. The restic-to-`anubis` backup script was kept but is no longer fed.
- **Cleanup completeness:** full — on-disk data gone. **Not restorable** without re-bootstrapping fresh.

### CryptPad (collaborative docs) — retired 2026-05-19, cleanup complete 2026-05-20

- **Why deployed:** the syncthing replacement for collaborative notes.
- **Why retired:** short-lived — the replacement didn't stick.
- **What we learned:** the **partial-cleanup anti-pattern**. The Flux Kustomization was removed first (2026-05-19), but the manifest tree, four `CRYPTPAD_*` config keys, and two CCNPs lingered as dead config for a day until the cleanup was finished (2026-05-20, `cb18de6`). Spin-downs should be done in one pass — remove the Kustomization *and* archive manifests *and* strip config keys *and* delete policies together (the wallabag/syncthing archives are the template).
- **Cleanup completeness:** complete in git (`grep cryptpad _lib _clusters terraform` is clean; tree archived to `_docs/archive/cryptpad/`). **Only remaining step:** confirm the `dev-cryptpad-data-pvc` TrueNAS zvol is destroyed. **Not intended to return.**

**Meta-lesson:** three knowledge tools deployed and retired in a week. The recurring reach for "one tool for articles + feeds + notes" is the case for deciding the unified-app question deliberately — see [ADR-0005](decisions/0005-thoth-knowledge-app.md).
