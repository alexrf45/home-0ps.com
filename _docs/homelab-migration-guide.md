# Homelab Migration & Implementation Guide

> Generated: 2026-04-02  
> Scope: home-0ps.com GitOps cluster (`dev` / memphis)  
> Method: Full repository audit + structured brainstorm against current state

---

## Context

This guide documents prioritized refactors and new implementations for the
`home-0ps.com` Kubernetes homelab. The cluster is operational with a clean
GitOps architecture (Flux CD, Talos Linux, Cilium, 1Password ESO) but is
running in a minimal state: one application deployed, security policies
entirely disabled, and no observability stack present.

The goal is a production-aspiring homelab demonstrating cloud-native best
practices: GitOps, mTLS, policy-as-code, self-hosted data sovereignty.

---

## Decision Log

| # | Decision | Alternatives Considered | Rationale |
|---|----------|------------------------|-----------|
| D-1 | Retain Flux layered dependency model | Flat kustomize, ArgoCD | Clean separation, explicit ordering, proven in repo |
| D-2 | Prometheus + Grafana for observability | Datadog, VictoriaMetrics | Already referenced in CLAUDE.md stack; open source |
| D-3 | Enable Kyverno before Falco | Falco first | Kyverno blocks bad state at admission; Falco detects at runtime — prevention before detection |
| D-4 | Cilium NetworkPolicy before service mesh | Linkerd, Istio | Cilium already deployed; eBPF-native policies without sidecar overhead |
| D-5 | Delete `_applications/` legacy manifests | Archive them | `_lib/applications/` is the canonical pattern; duplication causes drift |
| D-6 | Single external-dns-cloudflare instance | Keep both instances | Unless a second DNS provider is confirmed, dual instances create TXT record conflicts |
| D-7 | letsencrypt-production cert for Wallabag | Keep staging | Staging certs break real browser trust; no reason to keep staging in a live cluster |
| D-8 | Barman ObjectStore CRD must be declared in-repo | Manual creation | GitOps requires all state be in Git; undeclared CRs are invisible to Flux |

---

## Priority Tiers

### CRITICAL — Correctness & Data Integrity

These are gaps that risk data loss, silent failures, or broken trust in the
GitOps model. Address before adding new applications.

---

#### C-1: Declare Barman ObjectStore in Git

**Problem:** The `barman-cloud` plugin is deployed but no `ObjectStore` CRD
instance is visible in the repo. Without it, CNPG clusters have no backup
target — the plugin does nothing.

**What to do:**
1. Add `_lib/storage/barman-cloud/objectstore.yaml` with an `ObjectStore`
   resource pointing to the Wallabag S3 bucket provisioned by Terraform.
2. Reference the S3 credentials via an `ExternalSecret` (not a hardcoded
   `SecretKeyRef`) to keep the secrets flow consistent.
3. Add a `Backup` or `ScheduledBackup` resource to the Wallabag CNPG cluster.
4. Verify by running:
   ```bash
   kubectl get objectstore -n database
   kubectl get scheduledbackup -n wallabag
   ```

**Files to create/modify:**
- `_lib/storage/barman-cloud/objectstore.yaml` (new)
- `_lib/applications/wallabag/base/database.yaml` (add ScheduledBackup)
- `_lib/applications/wallabag/base/externalsecret-s3.yaml` (new)

---

#### C-2: Switch Wallabag to letsencrypt-production

**Problem:** The wildcard certificate in `_lib/networking/gateway/` references
`letsencrypt-staging`. Staging certificates are not trusted by browsers or
mobile apps — breaking the iOS app parity goal.

**What to do:**
```yaml
# _lib/networking/gateway/certificate.yaml
spec:
  issuerRef:
    name: letsencrypt-production   # was: letsencrypt-staging
    kind: ClusterIssuer
```

**Note:** Let's Encrypt production has rate limits (5 duplicate certs/week).
Confirm the staging cert is working first (it is — just untrusted), then flip
to production once.

---

#### C-3: Consolidate Duplicate Wallabag Manifests

**Problem:** `_applications/wallabag/` and `_lib/applications/wallabag/` both
exist. Flux reconciles `_lib/applications/wallabag/overlays/dev` per
`cluster.yaml`. The `_applications/` path is not referenced in any
Kustomization — but its presence creates confusion and risks accidental
reactivation.

**What to do:**
1. Confirm `_applications/wallabag/` is not referenced anywhere:
   ```bash
   grep -r "_applications/wallabag" _clusters/
   ```
2. If unreferenced, delete `_applications/` entirely.
3. If it serves a different purpose (e.g., a non-Flux manual install path),
   add a `README.md` inside explaining its status.

---

### HIGH — Security Hardening

The security layer is architecturally present but entirely disabled. These
policies should be enabled incrementally, starting with the least disruptive.

---

#### H-1: Enable Kyverno Policies (Admission Control First)

**Problem:** `_lib/security/kyverno-policies/` is commented out in the
security layer's `kustomization.yaml`. Without it, there is no enforcement of
baseline pod security standards, image policy, or label requirements.

**Recommended rollout order:**

1. **Audit mode first** — set `validationFailureAction: Audit` on all policies.
   This logs violations without blocking workloads.
2. Review violations in Kyverno reports:
   ```bash
   kubectl get policyreport -A
   ```
3. Fix violations in existing manifests (Wallabag, operators).
4. Switch policies to `Enforce` mode one at a time.

**Minimum policy set to start with:**
```yaml
# Policies to enable in _lib/security/kyverno-policies/
- disallow-latest-tag.yaml           # Prevent :latest image tags
- require-resource-limits.yaml       # All containers must have limits
- disallow-privileged-containers.yaml
- require-ro-root-filesystem.yaml    # Read-only root FS
- require-labels.yaml                # app.kubernetes.io/name required
```

**Key exclusions to maintain** (already in Kyverno values):
- `kube-system`, `flux-system`, `networking`, `database`, `cert-manager`

---

#### H-2: Enable Cilium NetworkPolicies (Zero-Trust Namespace Isolation)

**Problem:** `_lib/security/cilium-network-policies/` is disabled. All pods
can communicate with all other pods — defeating the purpose of namespace
isolation.

**Recommended rollout:**

1. Start with a **default-deny** policy per namespace:
   ```yaml
   # _lib/security/cilium-network-policies/default-deny.yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata:
     name: default-deny
   spec:
     endpointSelector: {}
     ingress: []
     egress:
       - toEndpoints:
           - matchLabels:
               io.kubernetes.pod.namespace: kube-dns
         toPorts:
           - ports:
               - port: "53"
                 protocol: ANY
   ```

2. Add explicit allow rules for each application:
   - Wallabag → PostgreSQL (CNPG)
   - Wallabag → Redis
   - ESO → 1Password Connect
   - External DNS → Kubernetes API

3. Enable the `cilium-network-policies` path in:
   `_lib/security/kustomization.yaml`

---

#### H-3: Enable Falco with Talos-Compatible Driver

**Problem:** Falco is disabled and referenced in CLAUDE.md as part of the
active stack. Talos Linux restricts kernel module loading — Falco must use the
eBPF driver, not the kernel module driver.

**Talos-specific requirements:**
```yaml
# _lib/controllers/falco/values.yaml
driver:
  kind: ebpf        # NOT module — Talos has no kernel modules
  ebpf:
    leastPrivileged: true

falco:
  grpc:
    enabled: true
  grpcOutput:
    enabled: true
```

**Additional Talos requirements:**
- The Falco eBPF probe needs `/proc`, `/sys`, and `/dev` host mounts.
- Talos allows this via a `MachineConfig` extension or by using
  `falco-driver-loader` in init container mode.
- Consider `falcosidekick` for routing alerts to a webhook/Slack/PagerDuty.

**Files to update:**
- `_lib/controllers/falco/` — add eBPF driver configuration
- `_lib/security/kustomization.yaml` — uncomment `falco-rules`

---

#### H-4: Add Namespace ResourceQuotas and LimitRanges

**Problem:** No namespace has a `ResourceQuota` or `LimitRange`. Unbounded
workloads can starve the node pool.

**Add to each application namespace:**
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: default-quota
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
```

**Namespaces to start with:** `wallabag`, `onepassword`, `external-secrets`

---

### HIGH — Observability Stack

Referenced in CLAUDE.md (`Prometheus`, `Grafana`, `Loki`, `FluentBit`) but
absent from the repo. Without it, the cluster is operating blind.

---

#### O-1: Deploy kube-prometheus-stack

**Layer:** Add a new `observability` Kustomization in `_clusters/dev/cluster.yaml`

**Dependency:** `depends on: [networking, storage]` — needs persistent storage
for Prometheus data and Gateway for Grafana ingress.

**Recommended HelmRelease:**
```yaml
# _lib/observability/kube-prometheus-stack/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  interval: 30m
  chart:
    spec:
      chart: kube-prometheus-stack
      version: ">=65.0.0"
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
  values:
    prometheus:
      prometheusSpec:
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: iscsi   # TrueNAS-backed
              resources:
                requests:
                  storage: 50Gi
        retention: 30d
    grafana:
      adminPassword: ""   # via ExternalSecret
      ingress:
        enabled: false     # use HTTPRoute instead
    alertmanager:
      enabled: true
```

**Add HTTPRoute for Grafana:**
```yaml
hostnames: ["grafana.home-0ps.com"]
parentRef: dev-app-gateway
backendRef: kube-prometheus-stack-grafana:80
```

---

#### O-2: Deploy Loki + FluentBit Log Stack

**Why Loki over ELK:** Lower resource footprint; integrates natively with
Grafana (single pane of glass).

```
_lib/observability/
├── loki/
│   └── helmrelease.yaml     # grafana/loki chart, S3 backend
├── fluentbit/
│   └── helmrelease.yaml     # DaemonSet on all nodes
└── kustomization.yaml
```

**Loki storage:** Use the Wallabag S3 bucket pattern — provision a dedicated
S3 bucket via Terraform (`terraform/dev/loki-s3/`) for log storage.

**FluentBit → Loki pipeline:**
```
[node logs] → FluentBit → Loki → Grafana
[pod logs]  → FluentBit → Loki → Grafana
```

---

#### O-3: Add ServiceMonitors for All Operators

Cert-manager already has a `ServiceMonitor` enabled. Extend to:

| Component | Config Needed |
|-----------|--------------|
| CNPG | `monitoring.enablePodMonitor: true` in HelmRelease values |
| External Secrets | `metrics.service.enabled: true` |
| Kyverno | `admissionController.serviceMonitor.enabled: true` |
| Cilium | Already exposes metrics; add ServiceMonitor |
| 1Password Connect | Custom ServiceMonitor (non-Helm) |

---

### MEDIUM — Resilience & GitOps Hygiene

---

#### R-1: Add PodDisruptionBudgets

**Problem:** Node drains (Talos upgrades, Proxmox maintenance) can evict all
replicas of a deployment simultaneously.

**Add to every stateless workload:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: wallabag-pdb
  namespace: wallabag
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: wallabag
```

**Add to `base/` for each app in `_lib/applications/`.**

---

#### R-2: Fix Wallabag Resource Limits

**Problem:** `200m CPU / 256Mi memory` is insufficient for a PHP Symfony app
with active users, a PostgreSQL connection, and Redis.

**Recommended values:**
```yaml
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 1000m      # was 200m
    memory: 1Gi     # was 256Mi
```

**File:** `_lib/applications/wallabag/base/deployment.yaml`

---

#### R-3: Add HPA for Wallabag

Once resource limits are corrected, add horizontal autoscaling:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: wallabag
  namespace: wallabag
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: wallabag
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**Note:** HPA requires Metrics Server to be deployed. Add it to the
`controllers` layer.

---

#### R-4: Resolve Dual External-DNS Instances

**Problem:** Two ExternalDNS HelmReleases exist (`external-dns` and
`external-dns-cloudflare`). If both manage the same zone, TXT ownership
records will conflict and records will fight each other.

**Investigation steps:**
```bash
kubectl get helmrelease -n networking
kubectl logs -n networking -l app.kubernetes.io/name=external-dns
```

**Resolution options:**
- **If both point to Cloudflare:** Delete one; keep `external-dns-cloudflare`
  with the full source list (`gateway-httproute`, `ingress`, `service`).
- **If they serve different providers:** Document the split in
  `_lib/dns/README.md` and ensure `domainFilters` are non-overlapping.

---

#### R-5: Verify Renovate Configuration

**Problem:** Renovate is deployed but its effectiveness is unknown without
verifying the `renovate.json` / `config.json` in the repo.

**Check:**
```bash
ls -la .github/  # Renovate config location
kubectl logs -n renovate -l app=renovate
```

**Minimum effective Renovate config for this stack:**
```json
{
  "extends": ["config:base"],
  "kubernetes": {
    "fileMatch": ["_lib/.+\\.yaml$", "_clusters/.+\\.yaml$"]
  },
  "helm-values": {
    "fileMatch": ["_lib/.+values\\.yaml$"]
  },
  "flux": {
    "fileMatch": ["_lib/.+\\.yaml$"]
  },
  "packageRules": [
    {
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    }
  ]
}
```

---

### MEDIUM — Application Expansion

The goal is a suite of self-hosted services with iOS app equivalents.

---

#### A-1: Application Readiness Checklist

Every new application added to `_lib/applications/<app>/base/` must include:

| Resource | Required | Notes |
|----------|----------|-------|
| `namespace.yaml` | Yes | |
| `deployment.yaml` | Yes | With resource limits |
| `service.yaml` | Yes | ClusterIP |
| `httproute.yaml` | Yes | Gateway API (not Ingress) |
| `externalsecret.yaml` | Yes | No hardcoded secrets |
| `pdb.yaml` | Yes | minAvailable: 1 |
| `networkpolicy.yaml` | Yes | Default deny + explicit allows |
| `kyverno-exception.yaml` | If needed | Document any policy exceptions |
| iOS app verified | Yes | Per CLAUDE.md goal |

---

#### A-2: Recommended Next Applications

Priority order based on the stated user goals (poetry, notes, links, media):

| App | Purpose | iOS App | Pattern |
|-----|---------|---------|---------|
| **Silverbullet** | Notes / wiki (already in stack) | Silverbullet PWA | CNPG or SQLite |
| **FreshRSS** | RSS reader (already in stack) | Reeder, NetNewsWire | MariaDB (operator already deployed) |
| **Nextcloud** | Files, calendar, contacts | Nextcloud iOS | CNPG + TrueNAS PVC |
| **Immich** | Photo management | Immich iOS | CNPG + large TrueNAS PVC |
| **Miniflux** | Lightweight RSS (alt to FreshRSS) | Reeder, Fiery Feeds | CNPG |
| **Bookmarks (Linkding)** | Link curation (alt/complement to Wallabag) | Linkding iOS | SQLite or CNPG |

**Note:** Silverbullet and FreshRSS are already in `CLAUDE.md` as
`Applications/Services` — these should be the first two after Wallabag.

---

#### A-3: Silverbullet Deployment Template

Silverbullet is a single-binary Markdown wiki with no external database
requirement. Simplest next deployment:

```yaml
# _lib/applications/silverbullet/base/deployment.yaml
image: ghcr.io/silverbulletmd/silverbullet:latest
ports:
  - containerPort: 3000
volumeMounts:
  - name: data
    mountPath: /space
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: silverbullet-space
```

**PVC:** Use `storageClassName: iscsi` (TrueNAS) for data persistence.  
**iOS:** Access via Tailscale + Gateway HTTPRoute; native PWA in Safari.

---

### NICE-TO-HAVE — Platform Maturity

---

#### N-1: Internal Cert Rotation Automation

**Problem:** The internal CA keypair is SOPS-encrypted in the repo. When it
expires, the rotation process is manual and undocumented.

**Recommendation:**
- Document the CA rotation procedure in `_docs/cert-rotation.md`
- Set `duration: 87600h` (10 years) on the internal CA `Certificate` resource
- Set `renewBefore: 720h` (30 days) for auto-renewal via cert-manager
- Add a Grafana alert on cert expiry < 30 days (requires O-1 first)

---

#### N-2: Flux Notification Controller

**What's missing:** No Flux alerts configured. Reconciliation failures are
silent unless you run `flux get kustomizations` manually.

**Add to `_clusters/dev/`:**
```yaml
# notification-provider.yaml (Slack or ntfy)
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-bot
  namespace: flux-system
spec:
  type: slack
  secretRef:
    name: slack-webhook
---
# alert.yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: on-call-alert
  namespace: flux-system
spec:
  providerRef:
    name: slack-bot
  eventSeverity: error
  eventSources:
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
```

---

#### N-3: OCI Image Automation with Flux Image Reflector

**Why:** Renovate handles Helm chart updates, but container image tag updates
for non-Helm apps (direct `image:` in Deployment) need Flux Image Automation.

```yaml
# _lib/controllers/flux-image-automation/
ImageRepository → ImagePolicy → ImageUpdateAutomation
```

This enables automated image tag promotion through Git commits from Flux
itself — closing the loop on GitOps for container images.

---

#### N-4: Talos Node Upgrade Documentation

`_hack/scripts/upgrade.sh` exists but the procedure is undocumented in `_docs/`.

**Create `_docs/talos-upgrade.md` covering:**
1. Pre-upgrade: `talosctl health`, verify Flux reconciliation is clean
2. Upgrade sequence: control plane first (one node at a time), then workers
3. Post-upgrade: `talosctl health`, `kubectl get nodes`, `flux get kustomizations`
4. Rollback: Talos machine config revert procedure

---

#### N-5: Trivy Operator for Image Scanning

Trivy is listed in the security stack but disabled. Unlike Falco (runtime),
Trivy is an admission/scanning tool — lower operational risk to enable.

```yaml
# _lib/security/trivy/helmrelease.yaml
HelmRelease: trivy-operator
  values:
    operator:
      scanJobTolerations: []
    trivy:
      ignoreUnfixed: true
    serviceMonitor:
      enabled: true  # feeds into Grafana dashboard
```

**Enable separately from Kyverno/Falco** — it only scans, never blocks.

---

## Implementation Sequence

Recommended execution order respecting dependencies:

```
Week 1 — Correctness
  [C-3] Delete _applications/ legacy manifests
  [C-2] Flip cert to letsencrypt-production
  [C-1] Declare Barman ObjectStore + ScheduledBackup

Week 2 — Security Foundation  
  [H-4] Add ResourceQuotas + LimitRanges
  [R-2] Fix Wallabag resource limits
  [H-1] Enable Kyverno in Audit mode → review reports → Enforce

Week 3 — Observability
  [O-1] Deploy kube-prometheus-stack
  [O-3] Add ServiceMonitors for all operators
  [N-2] Add Flux Notification Controller (alerts before you need them)

Week 4 — Network Security
  [H-2] Enable Cilium NetworkPolicies (default-deny + explicit allows)
  [R-4] Resolve dual external-dns
  [R-1] Add PodDisruptionBudgets

Week 5 — Runtime Security + Logs
  [H-3] Enable Falco with eBPF driver
  [N-5] Enable Trivy operator
  [O-2] Deploy Loki + FluentBit

Week 6 — Application Expansion
  [A-2/A-3] Deploy Silverbullet
  [A-2] Deploy FreshRSS
  [R-3] Add HPA for Wallabag + Metrics Server

Ongoing
  [R-5] Verify Renovate config
  [N-1] Document cert rotation
  [N-3] OCI Image Automation
  [N-4] Talos upgrade runbook
```

---

## Files to Create / Modify (Summary)

| Action | Path |
|--------|------|
| CREATE | `_lib/storage/barman-cloud/objectstore.yaml` |
| CREATE | `_lib/applications/wallabag/base/externalsecret-s3.yaml` |
| MODIFY | `_lib/applications/wallabag/base/database.yaml` — add ScheduledBackup |
| MODIFY | `_lib/networking/gateway/certificate.yaml` — production issuer |
| MODIFY | `_lib/applications/wallabag/base/deployment.yaml` — resource limits |
| CREATE | `_lib/applications/wallabag/base/pdb.yaml` |
| CREATE | `_lib/applications/wallabag/base/hpa.yaml` |
| MODIFY | `_lib/security/kustomization.yaml` — uncomment all policies |
| MODIFY | `_lib/controllers/falco/` — add eBPF driver config |
| CREATE | `_lib/observability/` — full directory with kube-prometheus-stack, loki, fluentbit |
| MODIFY | `_clusters/dev/cluster.yaml` — add `observability` Kustomization layer |
| CREATE | `_lib/applications/silverbullet/` — full base + overlay |
| CREATE | `_lib/applications/freshrss/` — full base + overlay |
| DELETE | `_applications/` — legacy manifests (after confirming unreferenced) |
| CREATE | `_clusters/dev/notifications.yaml` — Flux alert + provider |
| CREATE | `_docs/cert-rotation.md` |
| CREATE | `_docs/talos-upgrade.md` |

---

*This guide was generated from a full repository audit on 2026-04-02.
Re-audit recommended after each major implementation phase.*
