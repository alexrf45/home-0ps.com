# home-0ps.com Review — 2026-04-27

> Generated: 2026-04-27
> Scope: Status update against `home-0ps-migration-review.md` and `homelab-migration-guide.md` (both ~2026-04-02), plus a focused Terraform module evaluation
> Trigger: Physical relocation of the home lab hardware (6 Beelink mini PCs, UniFi networking, Zimaboard NAS) to a new location

---

## Executive Summary

The hardware moved; the code didn't. Git log confirms zero infrastructure changes in the 25 days since the prior reviews — only Claude Code agent/skill commits (`#36`, `#37`). User has confirmed:

- **Network:** Same subnet (`192.168.20.0/24`) — no IP rework required
- **Cluster state:** Needs fresh provision (`terraform apply` with `bootstrap_cluster = true`)

**Headline finding:** The structural repo migration described in `home-0ps-migration-review.md` is **complete**. The old `controllers/`, `applications/`, and `components/` directories are gone. The new `_lib/` layout with an 11-layer Flux DAG (`_clusters/dev/cluster.yaml`) is canonical and operational. The original review's seven issues are largely resolved.

The roadmap in `homelab-migration-guide.md`, however, has barely moved. Most CRITICAL/HIGH items are still open, and one item (Wallabag resource limits) is a guaranteed OOMKill on first request. The fresh provision is an opportunity to land both the deferred application/security work and the Terraform module refactors at once.

---

## Section 1 — Migration Review Status (7 Issues)

| # | Issue | Status | Evidence |
|---|-------|--------|----------|
| 1 | Duplicated controller definitions | ✅ Resolved | Old `controllers/`, `applications/`, `components/` directories no longer exist; `_lib/controllers/` is canonical |
| 2 | `infrastructure/` directory mixing concerns | ✅ Resolved | `_lib/` is split cleanly: `controllers/`, `pki/`, `secrets/`, `networking/`, `dns/`, `storage/`, `security/`, `applications/` — each layer has its own Flux Kustomization with explicit `dependsOn` |
| 3 | HelmRelease namespace inconsistency | ✅ Resolved | Sampled HelmReleases all use `namespace: flux-system` + `targetNamespace: <real-ns>` |
| 4 | Kustomizations + HelmReleases + postBuild | ✅ Resolved | `_clusters/dev/config/cluster-configs.yaml` provides a `cluster-config` ConfigMap; downstream Kustomizations consume it via `postBuild.substituteFrom` (see `_clusters/dev/cluster.yaml` lines 57–60, 135–138, 166–169, 192–195, 218–221, 244–247, 275–278) |
| 5 | Gateway duplication | ✅ Resolved | Single parameterized gateway in `_lib/networking/gateway/` using `${GATEWAY_NAME}`; per-environment gateway directories are gone |
| 6 | `gotk-components.yaml` duplication | ✅ Resolved (effectively) | `flux_bootstrap_git` resource in `terraform/dev/main.tf` handles Flux installation; the single hand-edited `gotk-components.yaml` per cluster is no longer the maintenance burden it was |
| 7 | Renovate scanning stale paths | ✅ Resolved (2026-04-27) | `_lib/controllers/renovate/helmrelease.yaml` updated: `clusters/` → `_clusters/`, removed stale `_applications/` include (added to ignorePaths), `apps/` kubernetes fileMatch → `_lib/applications/`, `_flux_templates` ignore → `_templates`, added `global/` to includePaths |

**Net result:** The migration review can be retired. All seven issues are now resolved.

---

## Section 2 — Implementation Roadmap Status

The roadmap from `homelab-migration-guide.md` defined CRITICAL → NICE-TO-HAVE tiers. Status against the current tree:

### CRITICAL — Correctness & Data Integrity

| ID | Item | Status | Notes |
|----|------|--------|-------|
| C-1 | Declare Barman ObjectStore in Git | ✅ Done | `_lib/applications/wallabag/overlays/dev/ob-archiver.yaml` and `ob-recovery.yaml` define ObjectStore CRs; `database.yaml` defines a `ScheduledBackup` (daily at `0 0 * * *`); S3 creds via `aws-creds` ExternalSecret |
| C-2 | Switch wildcard cert to letsencrypt-production | ❌ Not done | `_lib/networking/gateway/tls.yaml:10` still references `letsencrypt-staging`. Both ClusterIssuers exist in `_lib/networking/clusterissuers/cluster-issuers.yaml`. **One-line change.** |
| C-3 | Delete `_applications/` legacy manifests | ✅ Done (2026-04-27) | `_applications/` directory deleted. Renovate `includePaths` (Issue 7) and `ignorePaths` (transitional `**/_applications/**` entry) cleaned up. `CLAUDE.md` directory layout table updated to drop the row and add `_docs/`. |

### HIGH — Security Hardening

| ID | Item | Status | Notes |
|----|------|--------|-------|
| H-1 | Enable Kyverno policies | ⚠️ Audit mode enabled, partial labeling (2026-04-27) | All 9 validation policies flipped from `Enforce` → `Audit`; `kyverno-policies` uncommented in `_lib/security/kustomization.yaml`. Wallabag deployment hardened (explicit non-root securityContext, runAsUser=33, NET_BIND_SERVICE cap, required `app.kubernetes.io/*` labels, imagePullPolicy=Always) but **wallabag namespace not yet labeled** — verify the hardened pod actually starts before adding `home-0ps.com/policy-target: "application"` to `_lib/applications/wallabag/base/namespace.yaml`. New apps (FreshRSS, Obsidian Live-Sync) scaffolded with namespace label baked in — they will produce real audit findings once wired into Flux. |
| H-2 | Enable Cilium NetworkPolicies | ❌ Not done | `_lib/security/cilium-network-policies/` contains only one stale policy (`obsidian-couchdb-networkpolicy.yaml` — for a service that isn't deployed). No default-deny, no per-app allow rules |
| H-3 | Enable Falco | ❌ Not done | `_lib/controllers/kustomization.yaml:7` has `#  - ./falco`. The HelmRelease at `_lib/controllers/falco/helmrelease.yaml` is already configured for Talos (`modern_ebpf` driver, containerd socket, falcosidekick + UI, ServiceMonitors). Just uncomment after observability is in place to consume the metrics |
| H-4 | ResourceQuotas + LimitRanges per namespace | ❌ Not done | No `ResourceQuota`/`LimitRange` objects anywhere in `_lib/` |

### HIGH — Observability

| ID | Item | Status | Notes |
|----|------|--------|-------|
| O-1 | kube-prometheus-stack | ❌ Not done | No `_lib/observability/` directory exists. Prometheus Operator CRDs are deployed (`global/crds/prometheus-operator-crds/`) but no Prometheus instance, no Grafana, no Alertmanager |
| O-2 | Loki + FluentBit | ❌ Not done | — |
| O-3 | ServiceMonitors for operators | ❌ Not done | Falco's HelmRelease has them pre-wired, but no scraper exists yet |

### MEDIUM — Resilience

| ID | Item | Status | Notes |
|----|------|--------|-------|
| R-1 | PodDisruptionBudgets | ❌ Not done | — |
| R-2 | Fix Wallabag resource limits | ✅ Done (2026-04-27) | `_lib/applications/wallabag/base/deployment.yaml` limits raised to `memory: 1Gi` / `cpu: 1000m`, requests to `memory: 256Mi` / `cpu: 100m`. PHP_MEMORY_LIMIT (500M) now well below the container ceiling. Bundled with the wallabag securityContext hardening. |
| R-3 | HPA for Wallabag | ❌ Not done | Single replica; no autoscaler |
| R-4 | Resolve dual external-dns | ✅ Done (2026-04-27) | `_lib/dns/external-dns-cloudflare/` directory deleted. Only the UniFi webhook variant remains (`external-dns` targeting `10.3.3.1`). Cloudflare creds for cert-manager DNS-01 are unaffected — they live independently in `_lib/networking/clusterissuers/cf-secrets.yaml`. |
| R-5 | Verify Renovate config | ✅ Done (2026-04-27) | In-cluster Renovate config corrected: `_clusters/` instead of `clusters/`, `_lib/applications/` instead of `apps/`, `_applications/` moved to ignorePaths (will go away with C-3), `_templates` instead of `_flux_templates`, `global/` added to includePaths. Root `renovate.json` remains a minimal schema-only file (intentional — in-cluster config is authoritative). |

### MEDIUM — Application Expansion

| ID | Item | Status |
|----|------|--------|
| A-1 | Application readiness checklist | ⚠️ Implicit | The pattern is now codified across 3 apps (wallabag, freshrss, obsidian-livesync) — namespace + ExternalSecret + Deployment with policy-compliant securityContext + Service + HTTPRoute + optional CNPG cluster overlay. Worth lifting into a documented template. |
| A-2 | Deploy Silverbullet | ❌ Not done |
| A-3 | Deploy FreshRSS | ⚠️ Scaffolded (2026-04-27) | Built at `_lib/applications/freshrss/{base,overlays/dev}/`. Postgres via CNPG, local-path PVC, FreshRSS 1.27.0-alpine running as UID 65534, NET_BIND_SERVICE cap. **Not yet wired into Flux** — see "Wiring new apps into Flux" below. Requires 1Password entry `freshrss_dev`. |
| A-4 | Deploy Obsidian Live-Sync | ⚠️ Scaffolded (2026-04-27) | Built at `_lib/applications/obsidian-livesync/{base,overlays/dev}/`. CouchDB 3.4.2 single-node, local-path PVC, ConfigMap with CORS for Obsidian client, runs as UID 5984. **Not yet wired into Flux**. Requires 1Password entry `obsidian-livesync_dev`. |

Only Wallabag is live in the cluster. FreshRSS + Obsidian Live-Sync are scaffolded but not yet reconciled. The placeholder directories under `_applications/` were never built out — still scheduled for deletion per C-3.

### NICE-TO-HAVE

All 5 items (cert rotation automation, Flux notification controller, OCI image automation, Talos upgrade docs, Trivy operator) are still open. Trivy in particular is set up at `_lib/security/trivy/` but commented out in the security kustomization.

---

## Section 3 — Terraform Module Evaluation

Module under review: **`terraform/dev/talos-pve-v3.1.0/`**. State backend: S3 (`dev-khepri-state-913f37f7-9735-8205-17da-48f4072a2d0e`, `state/dev/dev001-v1.12.4.tfstate`, `use_lockfile = true`).

### 3.1 Stability assessment

The module is **functional and reproducible**. It hangs together cleanly:

- 11 `.tf` files split by concern (`pve.tf`, `talos.tf`, `pve-images.tf`, `talos-images.tf`, `cilium_config.tf`, `config-export.tf`, `worker-labels.tf`, `locals.tf`, `random.tf`, plus `terraform.tf` / `variables.tf` / `outputs.tf`)
- Variable validation uses meaningful error messages (env enum, alphanumeric cluster name, odd-count CP quorum)
- Sensitive outputs are correctly marked
- Provider pinning is sound — exact pins on the high-risk providers (`siderolabs/talos = 0.10.1`, `fluxcd/flux = 1.7.6`, `1Password/onepassword = 3.2.1`); `~>` on the Hashicorp helpers
- `terraform.tfvars` is correctly excluded from git via `.gitignore` (lines 268, 293) — verified with `git ls-files` returning empty
- Bootstrap path is end-to-end automated: image factory → PVE image download → VM create → machine config apply → bootstrap → kubeconfig export to 1Password → worker labels → Flux bootstrap

**Confidence to re-provision the cluster as-is: high.** The blockers below are quality issues, not correctness issues.

### 3.2 Refactoring recommendations

Ranked by ROI given the imminent fresh provision:

#### R1 — Collapse `pve.tf` controlplane/worker duplication (HIGH, do during provision)

**File:** `terraform/dev/talos-pve-v3.1.0/pve.tf`

`proxmox_virtual_environment_vm.controlplane` (lines 3–93) and `proxmox_virtual_environment_vm.worker` (lines 96–187) are 99% identical. Differences are limited to: name prefix, description, tags, and which `talos_*_image` resource feeds `disk[0].file_id`.

**Recommendation:** Build a single resource with `for_each` over a merged map keyed by role. Sketch:

```hcl
locals {
  all_nodes = merge(
    { for k, v in var.controlplane_nodes : "cp-${k}" => merge(v, {
      role        = "controlplane"
      description = "Talos Control Plane"
      tags        = ["k8s", "controlplane", var.env]
      file_id     = proxmox_virtual_environment_download_file.talos_control_plane_image[0].id
    }) },
    { for k, v in var.worker_nodes : "node-${k}" => merge(v, {
      role        = "worker"
      description = "Talos Worker Node"
      tags        = ["k8s", "node", var.env]
      file_id     = proxmox_virtual_environment_download_file.talos_worker_image[0].id
    }) },
  )
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.all_nodes
  # ... single VM block referencing each.value.role/file_id/tags/description
}
```

**Why now:** This is a state-breaking change on a running cluster (resource addresses move). On a fresh provision there's no state to migrate — net cost is the refactor itself.

#### R2 — Extract shared Talos machine config (MEDIUM, do during provision)

**File:** `terraform/dev/talos-pve-v3.1.0/talos.tf`

`data.talos_machine_configuration.controlplane` (lines 16–163) and `.worker` (lines 166–249) share ~80% of their config patches: `systemDiskEncryption`, `sysctls`, `kernel.modules`, `files` (CRI customization), `time`, `kubelet`, `disks`, `install`, `network.nameservers/interfaces`. Drift between them is a real risk — for example, the worker patch silently lacks the worker pod-security admission exemptions because that block is CP-only.

**Recommendation:** Either:

- **Locals approach:** lift the shared block into a `local.shared_machine_patch` (yaml-encoded) and set `config_patches = [local.shared_machine_patch, local.cp_extras]` for CP, `[local.shared_machine_patch]` for worker; or
- **Template approach:** move the patch into `templates/machine-config.yaml.tftpl` and call `templatefile()` with a `role` parameter that gates CP-only blocks.

The locals approach is simpler; the template approach reads better when the patch grows.

#### R3 — Externalize hardcoded magic values — ✅ Done (2026-04-27)

**File:** `terraform/dev/talos-pve-v3.1.0/talos.tf` + `variables.tf` (also mirrored in root `terraform/dev/variables.tf`)

Added five new optional fields to `var.talos`:

| Field | Default | Replaces |
|-------|---------|----------|
| `pod_subnet` | `10.42.0.0/16` | hardcoded in CP + worker patches |
| `service_subnet` | `10.43.0.0/16` | hardcoded in CP + worker patches |
| `cluster_dns_ip` | `10.43.0.10` | hardcoded `kubelet.clusterDNS` in CP + worker |
| `ntp_servers` | `["time.cloudflare.com"]` | hardcoded `time.servers` in CP + worker |
| `extra_manifests` | pinned URLs (see below) | unpinned `main`/`latest` URLs in CP |

Pinned `extra_manifests` defaults:
- `kubelet-serving-cert-approver` → `v0.9.0` tag (was `main` branch)
- `metrics-server` → `v0.7.2` (was `latest`)
- `gateway-api` → `v1.4.0` (already pinned, now a variable)

Heredoc uses `%{for ... ~}` directives to render the list. Behavior preserved for current callers; users can override any field via `terraform.tfvars`. Companion validation rule ensures `cluster_dns_ip` actually lives inside `service_subnet`.

#### R4 — Add cross-variable IP validation — ✅ Done (2026-04-27)

**File:** `terraform/dev/talos-pve-v3.1.0/variables.tf`

Added validation blocks (Terraform 1.9+ cross-variable validation) on three fronts:

- `controlplane_nodes`: every node IP must be inside `cilium_config.node_network`
- `worker_nodes`: same
- `talos.vip_ip`: same
- `talos.cluster_dns_ip` (added with R3): must be inside `talos.service_subnet`
- `talos.pod_subnet` / `talos.service_subnet`: must be valid CIDR strings

Terraform has no native CIDR-containment function, so the trick is to compare network addresses:

```hcl
condition = alltrue([
  for v in var.controlplane_nodes :
  cidrhost("${v.ip}/${split("/", var.cilium_config.node_network)[1]}", 0) ==
  cidrhost(var.cilium_config.node_network, 0)
])
```

Verified: a typo IP outside the subnet now produces a clear plan-time error including the offending value and the network being checked against. Tested via synthetic module wrapper (`terraform validate` + `terraform plan`).

#### R5 — Worker memory typo — ✅ Done in module (2026-04-27)

**File:** `terraform/dev/talos-pve-v3.1.0/variables.tf:86` — fixed `8092` → `8192` while in the file for R3/R4. **Note:** the root `terraform/dev/variables.tf:76` and `terraform/dev/terraform.tfvars` still carry `8092` — the user's tfvars overrides the default anyway, so the active worker memory is whatever's in tfvars. No-op for the running cluster but worth tidying up the next time tfvars is edited.

#### R6 — `bootstrap.sh` cleanup or removal — ✅ Done (2026-04-27)

**File:** `terraform/dev/bootstrap.sh` — **deleted**.

The script was largely redundant with the `flux_bootstrap_git` resource in `terraform/dev/main.tf`, and its active default was `destroy()` (a foot-gun). Removed entirely; SOPS-age secret seeding is now handled in Terraform via the `kubernetes_secret.sops_age` resource.

#### R7 — Documentation drift (LOW)

The module's README states `fluxcd/flux ~> 1.5.0` while `terraform.tf` pins `~> 1.7.6`. README also describes `local_sensitive_file` exports, but `config-export.tf` writes to 1Password. Bring the README into agreement with the code.

### 3.3 Out-of-scope but worth tracking

- `proxmox_virtual_environment_vm` `lifecycle.ignore_changes` includes `initialization` — that's correct for cloud-init drift but means changing IPs / DNS in tfvars won't trigger a replace. Document this so future-you doesn't get confused when an IP edit looks like a no-op.
- `time_sleep` resources (`wait_until_apply`, `wait_until_bootstrap`) are 30s each. On slower hardware this can be tight — consider parameterizing if you ever see flaky bootstraps.
- The module exports kubeconfig/talosconfig to 1Password but doesn't gate on a successful API call before declaring success. A failed 1Password write currently won't block apply.

---

## Section 4 — Pre-Provision Checklist

Same subnet, fresh provision. Run through this before `terraform apply`:

1. **Network reachability**
   - [ ] Proxmox cluster endpoint `192.168.20.6:8006` reachable
   - [ ] All six PVE hosts (`pve01`–`pve06`) up and joined to the PVE cluster
   - [ ] TrueNAS at `192.168.20.106` reachable, iSCSI portal `:3260` open
   - [ ] UniFi controller `10.3.3.1` reachable (external-dns webhook target)
   - [ ] Outbound internet works (Talos image factory, Cloudflare DNS-01, GitHub SSH, 1Password Connect, AWS S3)

2. **State + credentials**
   - [ ] S3 backend bucket `dev-khepri-state-...` accessible from the workstation running terraform
   - [ ] 1Password service account token in `terraform.tfvars` is current (the one in tree is the active token — rotate after provisioning if appropriate)
   - [ ] Proxmox root password in `terraform.tfvars` matches the relocated cluster
   - [ ] `bootstrap_cluster = true` in `terraform.tfvars` (currently set)

3. **Repo hygiene before provisioning**
   - [ ] Decide whether to land R1/R2 (terraform refactors) before or after this provision. Recommendation: land them first, ideally on a feature branch with a `terraform plan` review, since fresh state means no `terraform state mv` cost.
   - [x] ~~Fix `bootstrap.sh` (R6) or delete it~~ — deleted 2026-04-27
   - [x] ~~Pin the `extraManifests` URLs (R3)~~ — done 2026-04-27 (defaults pin kubelet-serving-cert-approver v0.9.0, metrics-server v0.7.2, gateway-api v1.4.0; override via tfvars if needed)
   - [x] ~~Cross-variable IP validation (R4)~~ — done 2026-04-27

4. **Post-bootstrap verification**
   - [ ] `kubectl get nodes` shows 6 Ready nodes
   - [ ] `flux get kustomizations` shows all 11 layers reconciling green
   - [ ] `kubectl get certificate -A` shows the wildcard issued (will still be a staging cert until C-2 lands)
   - [ ] Wallabag's CNPG cluster is healthy and Barman backups land in S3

---

## Section 5 — Revised Priority Recommendations

Re-ordered for the post-relocation context. The fresh provision creates a natural cut-line.

### Before / during provision

1. ~~**Fix Wallabag resource limits** (R-2)~~ — ✅ Done 2026-04-27 (limits raised to 1Gi/1000m).
2. **Switch to letsencrypt-production** (C-2) — one-line change in `_lib/networking/gateway/tls.yaml`. Confirm the staging cert worked at least once first; LE production has rate limits.
3. ~~**Pin Talos `extraManifests` URLs** (R3)~~ — ✅ Done 2026-04-27 (and externalized other magic values to `var.talos`).
4. **Land terraform refactors R1 + R2** — fresh state means zero migration cost. Best window you'll get.
5. ~~**Fix or delete `bootstrap.sh`** (R6)~~ — ✅ Done 2026-04-27 (deleted).
6. ~~**Delete `_applications/`** (C-3)~~ — ✅ Done 2026-04-27 (Renovate paths + CLAUDE.md cleaned up in the same change).

### Week 1 (cluster up, basics)

7. ~~Switch Kyverno policies from `Enforce` → `Audit`, then enable in `_lib/security/kustomization.yaml` (H-1).~~ — ✅ Done 2026-04-27. Still need to label the wallabag namespace once the hardened deployment is verified to start; new apps (FreshRSS, Obsidian Live-Sync) are labeled by default.
8. Add ResourceQuotas + LimitRanges per namespace (H-4) — pairs naturally with H-1.
9. ~~Cross-variable IP validation in the module (R4)~~ — ✅ Done 2026-04-27 (validates node IPs, VIP, and cluster DNS against their respective CIDRs at plan time).

### Week 2–3 (observability)

10. Deploy `_lib/observability/` with kube-prometheus-stack (O-1).
11. Add Loki + FluentBit (O-2).
12. Once metrics are flowing, enable Falco (H-3) and Trivy.

### Week 3–4 (network policy + apps)

13. Default-deny CiliumNetworkPolicy + per-app allow rules (H-2). Wallabag → CNPG → Redis flow is the test case.
14. Wallabag PDB + HPA (R-1, R-3).
15. Deploy Silverbullet (A-2) — it's the simplest next app (single binary, no DB).

### Week 4+ (app expansion + nice-to-haves)

16. FreshRSS (A-3).
17. Flux notification controller, OCI image automation, Talos upgrade docs (NICE-TO-HAVE).

---

## Section 6 — Wiring New Apps into Flux

The FreshRSS and Obsidian Live-Sync scaffolds are intentionally not referenced from `_clusters/dev/cluster.yaml` yet. To enable them, append the following blocks under the `applications` Kustomization in `_clusters/dev/cluster.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: freshrss
  namespace: flux-system
spec:
  dependsOn:
    - name: dns
    - name: storage
    - name: networking
    - name: external-secrets-operator
    - name: secrets
    - name: security
  interval: 10m
  retryInterval: 1m
  timeout: 10m0s
  path: ./_lib/applications/freshrss/overlays/dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: obsidian-livesync
  namespace: flux-system
spec:
  dependsOn:
    - name: dns
    - name: storage
    - name: networking
    - name: external-secrets-operator
    - name: secrets
    - name: security
  interval: 10m
  retryInterval: 1m
  timeout: 10m0s
  path: ./_lib/applications/obsidian-livesync/overlays/dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
```

### Required 1Password entries (vault: home-0ps)

Create these items before reconciling, otherwise the ExternalSecrets will stay in `SecretSyncedError`:

**`freshrss_dev`** — fields:
- `username` — Postgres role (suggest: `freshrss`)
- `password` — Postgres password (strong)
- `database` — Postgres database name (suggest: `freshrss`)
- `host` — `freshrss-dev-cluster-rw.freshrss.svc.cluster.local`
- `port` — `5432`
- `admin_user` — FreshRSS admin login
- `admin_password` — FreshRSS admin password (strong)
- `admin_email` — admin email address

**`obsidian-livesync_dev`** — fields:
- `username` — CouchDB admin user (suggest: `obsidian`)
- `password` — CouchDB admin password (strong, ≥32 chars; CouchDB stores it hashed but it's transmitted on every API call)

### Pre-reconciliation checklist

1. ✅ 1Password entries exist (above)
2. ✅ Wallabag deployment verified to start with the new securityContext (`kubectl rollout status -n wallabag deploy/wallabag`); if it fails, see "Wallabag hardening risks" below
3. ✅ Add `home-0ps.com/policy-target: "application"` label to `_lib/applications/wallabag/base/namespace.yaml` once #2 is verified — this turns on real audit findings for wallabag
4. ✅ Append the two Kustomization blocks to `_clusters/dev/cluster.yaml`
5. ✅ Bump the `applications` Kustomization's `dependsOn` is unaffected — the new ones are siblings, not children

### Wallabag hardening risks

The wallabag hardening (UID 33, dropped caps, NET_BIND_SERVICE) **may** prevent the container from starting. The `wallabag/wallabag` image's entrypoint runs `chown` operations that need root. Two likely outcomes:

- **Best case:** entrypoint chowns succeed because target ownership already matches → pod starts
- **Worst case:** entrypoint fails with permission denied → pod crashloops

If it crashloops, the cleanest mitigation is an init container (running as root, chowning the volumes) plus a main container running as UID 33. That's a deeper change worth a separate iteration. Verify before labeling the namespace.

---

## Section 7 — Files Referenced

| File | Why it matters |
|------|---------------|
| `_clusters/dev/cluster.yaml` | 11-layer Flux DAG; proves the structural migration is complete |
| `_clusters/dev/config/cluster-configs.yaml` | `cluster-config` ConfigMap consumed by `postBuild.substituteFrom` |
| `_lib/networking/gateway/tls.yaml` | Line 10: still `letsencrypt-staging` (C-2) |
| `_lib/security/kustomization.yaml` | All 4 entries commented out (H-1, H-2, H-3 partial, Trivy) |
| `_lib/controllers/kustomization.yaml` | Line 7: Falco commented out (H-3) |
| `_lib/applications/wallabag/base/deployment.yaml` | Lines 23–29 (limits) + line 65 (`PHP_MEMORY_LIMIT`) — OOMKill (R-2) |
| `_applications/` | 6 placeholder directories, none reconciled (C-3) |
| `terraform/dev/talos-pve-v3.1.0/pve.tf` | DRY violation between `controlplane` (3–93) and `worker` (96–187) (R1) |
| `terraform/dev/talos-pve-v3.1.0/talos.tf` | Shared machine config + hardcoded subnets/URLs (R2, R3) |
| `terraform/dev/talos-pve-v3.1.0/variables.tf` | Worker memory typo, line 74 (R5); place for cross-var validation (R4) |
| `terraform/dev/bootstrap.sh` | Stale repo URL (line 33), `destroy` default (line 52) (R6) |
| `terraform/dev/terraform.tfvars` | Local-only, gitignored. Holds Proxmox password + 1Password SA token. Verify before provisioning. |
