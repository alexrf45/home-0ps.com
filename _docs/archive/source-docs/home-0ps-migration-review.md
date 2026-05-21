# home-0ps.com Repo Migration Review

## Current State Assessment

The repo is mid-migration between two parallel structures. The **old structure** (`controllers/`, `applications/`, `components/`) is what Flux currently reconciles, while the **new structure** (`infrastructure/`) is being built alongside it. The cluster entrypoints (`clusters/{horus,memphis,abydos}/*.yaml`) still point to the old paths, so nothing from `infrastructure/` is live yet.

This is actually a good position to be in — you have breathing room to get the new structure right before flipping the switch. But there are several issues worth addressing before you wire it up.

---

## Issue 1: Duplicated Controller Definitions

The most immediate problem is that controller manifests exist in **both** structures with diverged configurations.

**Example: cert-manager**

The old `controllers/base/cert-manager/helmrelease.yaml` is a minimal definition with basic values, while `infrastructure/controllers/base/cert-manager/helmrelease.yaml` is a much more thorough definition with image digests, resource limits, pod labels, cainjector config, and Prometheus ServiceMonitor settings. They also run different versions — v1.18.2 (old) vs v1.19.3 (new).

The `infrastructure/` version is clearly the one you want going forward since it follows your security patterns (SHA256 digests, explicit resource limits, non-root enforcement). **Recommendation**: treat `infrastructure/` as the canonical source and plan to delete the old `controllers/base/` entirely once the migration is complete. Don't try to keep them in sync.

---

## Issue 2: The `infrastructure/` Directory Is Doing Too Much

Right now `infrastructure/` mixes two concerns that should stay separate in the new structure:

- **Controllers** (operators that need to be healthy before anything else runs): cert-manager, cloudnativepg, falco, kyverno, mariadb-operator, redis-operator, renovate
- **Infrastructure primitives** (resources that depend on controllers): networking/gateway, security/kyverno-policies, secrets/external-secrets+onepassword, storage/freenas-csi

This maps well to your migration strategy's 5-layer DAG (`components → controllers → infrastructure → security → apps`), but the current `infrastructure/` directory flattens everything under one roof. If you wire up a single Flux Kustomization pointing at `infrastructure/`, you lose the dependency ordering that the migration strategy is specifically designed to solve.

**Recommendation**: restructure `infrastructure/` to reflect the dependency layers, or (better yet) align with Strategy 1's `_lib/` pattern where these are consumed by per-cluster kustomization manifests that enforce the ordering.

---

## Issue 3: HelmRelease Namespace Inconsistency

Across the repo, HelmReleases and HelmRepositories inconsistently place resources in either the target namespace or `flux-system`. For example:

- `infrastructure/controllers/base/falco/helmrelease.yaml` puts the HelmRelease in `flux-system` with `targetNamespace: security`
- `controllers/base/onepassword-connect/deploy.yaml` puts the HelmRepository in `flux-system` but the namespace resource in the same file
- `infrastructure/controllers/base/renovate/helmrelease.yaml` has the HelmRelease in `flux-system` but the HelmRepository source points to `namespace: renovate`

The `flux-system` namespace approach works fine when Flux Kustomizations don't set `targetNamespace`, but it creates confusion when mixed with kustomizations that *do* set `targetNamespace`. The safest pattern for your setup is: **HelmReleases and HelmRepositories live in `flux-system`, and use `targetNamespace` to deploy into the correct namespace.** This is what most of your new `infrastructure/` definitions already do — just make it consistent.

---

## Issue 4: Kustomizations + HelmReleases + PostBuild (Your Core Question)

This is where the rubber meets the road. There are two distinct "Kustomization" concepts at play, and conflating them is the source of most of the confusion.

### The Two Kustomizations

**Kustomize `kustomization.yaml`** (`kustomize.config.k8s.io/v1beta1`) — This is the file that `kustomize build` reads. It lists resources, patches, and overlays. It runs at *build time* and produces static YAML. It does NOT support `postBuild`, `dependsOn`, `healthChecks`, or `decryption`. It's what you see in files like `controllers/base/cert-manager/kustomization.yaml`.

**Flux `Kustomization`** (`kustomize.toolkit.fluxcd.io/v1`) — This is a Kubernetes CR that the Flux kustomize-controller reconciles. It supports `postBuild`, `dependsOn`, `healthChecks`, `decryption`, and `sourceRef`. It's what you see in `clusters/horus/horus.yaml` and `infrastructure/storage/variants/dev.yaml`.

### The Pattern You Want

For HelmReleases that need per-environment configuration via `postBuild`, here's the clean approach that minimizes folders:

**Step 1**: Create a Kustomize base with the HelmRelease, HelmRepository, and namespace:

```yaml
# _lib/controllers/freenas-csi/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrepository.yaml
  - helmrelease.yaml
```

In the HelmRelease, use `${VARIABLE}` placeholders anywhere you need environment-specific values:

```yaml
# _lib/controllers/freenas-csi/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: freenas-csi-iscsi
  namespace: flux-system
spec:
  chart:
    spec:
      chart: democratic-csi
      version: "0.14.7"
      sourceRef:
        kind: HelmRepository
        name: democratic-csi
  targetNamespace: storage
  values:
    driver:
      config:
        httpConnection:
          host: "${TRUENAS_HOST}"
          apiKey: "${TRUENAS_API_KEY}"
        iscsi:
          targetPortal: "${TRUENAS_HOST}:3260"
```

**Step 2**: In each cluster directory, create a **Flux Kustomization** (not a kustomize kustomization) that points to the base and supplies the variables via `postBuild`:

```yaml
# clusters/horus/controllers.yaml (Flux Kustomization CR)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: freenas-csi
  namespace: flux-system
spec:
  dependsOn:
    - name: components
  interval: 30m
  path: ./_lib/controllers/freenas-csi
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
      - kind: Secret
        name: cluster-secrets
```

**Step 3**: Create a ConfigMap and Secret that live in the cluster, seeded during bootstrap:

```yaml
# clusters/horus/config/cluster-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: flux-system
data:
  CLUSTER_NAME: "horus"
  ENVIRONMENT: "prod"
  DOMAIN: "home-0ps.com"
  TRUENAS_HOST: "192.168.20.106"
  GATEWAY_NAME: "prod-app-gateway"
  ISSUER_NAME: "letsencrypt-production"
  STORAGE_CLASS: "iscsi"
```

### Why This Works

The key insight is that you **don't need per-environment overlay directories** at all if you use `postBuild` variable substitution. Your `_lib/` bases contain the HelmReleases with `${VAR}` placeholders. Your cluster-level Flux Kustomizations point at those bases and inject the values. No `variants/dev.yaml`, no `variants/prod.yaml`, no `controllers/prod/kustomization.yaml`. The environment differentiation happens entirely through the ConfigMap values and the Flux Kustomization wiring in each cluster directory.

This is exactly what your `infrastructure/storage/variants/dev.yaml` is already doing — it just needs to be elevated to a consistent pattern across all controllers.

### When You DO Need Kustomize Overlays

PostBuild variable substitution handles string replacement well, but it can't add or remove entire YAML blocks. For cases where environments differ structurally (e.g., prod Wallabag has 3 CNPG replicas with barman backups while dev has 2 replicas with no backups), you still need Kustomize patches. The approach is:

```yaml
# _lib/apps/wallabag/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - httproute.yaml
  - network-policy.yaml
```

```yaml
# _lib/apps/wallabag/overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../              # pulls in the base
  - database.yaml       # CNPG cluster with 3 replicas + backups
patches:
  - target:
      kind: Deployment
      name: wallabag
    patch: |
      - op: replace
        path: /spec/replicas
        value: 2
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: "512Mi"
```

Then the Flux Kustomization in `clusters/horus/` points at `_lib/apps/wallabag/overlays/prod` instead of the base.

---

## Issue 5: Gateway Duplication

You have nearly identical Gateway definitions in `applications/dev/dev-app-gateway/deploy.yaml`, `applications/prod/prod-app-gateway/deploy.yaml`, `applications/test/test-app-gateway/deploy.yaml`, and `infrastructure/networking/base/cilium-gateway/gateway.yaml`. Each differs only in the gateway name, namespace label selectors, and TLS issuer reference.

This is a prime candidate for a single parameterized base:

```yaml
# _lib/infrastructure/gateway/gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: networking
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: wildcard-tls
        namespace: networking
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            ${GATEWAY_NAME}: "true"
  - name: http-redirect
    protocol: HTTP
    port: 8080
    allowedRoutes:
      namespaces:
        from: All
```

With `GATEWAY_NAME` coming from the cluster ConfigMap, one base serves all three environments.

---

## Issue 6: The `gotk-components.yaml` Duplication

Your migration strategy already flagged this, and it's still present — each cluster has its own 2500+ line `gotk-components.yaml`. These are generated by `flux bootstrap` and shouldn't be hand-edited, but you can reduce the maintenance burden by ensuring all clusters run the same Flux version and using `flux bootstrap` consistently. The gotk-sync.yaml is the only file that should vary per cluster.

---

## Issue 7: Renovate Configuration Is Stale

The Renovate HelmRelease in `infrastructure/controllers/base/renovate/helmrelease.yaml` still has `includePaths` pointing at `controllers/base/`, `applications/base/`, and `components/`. Once you migrate to the new structure, this needs to be updated to scan `_lib/`, `infrastructure/`, or whatever the final paths are. If Renovate can't find your HelmReleases, you won't get automated version bump PRs.

---

## Recommended Target Structure

Based on your migration strategy (Strategy 1 hybrid with Strategy 3 modules) and the current state of the repo:

```
home-0ps.com/
├── _lib/                                  # Shared bases, never reconciled directly
│   ├── controllers/
│   │   ├── cert-manager/
│   │   │   ├── kustomization.yaml         # ns + helmrepo + helmrelease
│   │   │   ├── namespace.yaml
│   │   │   ├── helmrepository.yaml
│   │   │   └── helmrelease.yaml
│   │   ├── external-secrets/
│   │   ├── onepassword-connect/
│   │   ├── cloudnativepg/
│   │   ├── falco/
│   │   ├── kyverno/
│   │   ├── renovate/
│   │   ├── mariadb-operator/
│   │   └── redis-operator/
│   ├── infrastructure/
│   │   ├── gateway/                       # parameterized with ${GATEWAY_NAME}
│   │   ├── external-dns/
│   │   ├── cert-manager-issuers/
│   │   └── storage/
│   │       ├── freenas-csi/               # parameterized with ${TRUENAS_HOST} etc.
│   │       └── local-path/
│   ├── security/
│   │   ├── kyverno-policies/
│   │   ├── cilium-network-policies/
│   │   └── trivy/
│   └── apps/
│       ├── wallabag/
│       │   ├── base/                      # deployment, service, httproute
│       │   └── overlays/
│       │       ├── prod/                  # + database w/ backups, higher resources
│       │       └── dev/                   # + database w/o backups, lower resources
│       ├── freshrss/
│       ├── silverbullet/
│       └── adminer/
├── clusters/
│   ├── horus/
│   │   ├── flux-system/
│   │   │   ├── gotk-components.yaml
│   │   │   ├── gotk-sync.yaml
│   │   │   └── kustomization.yaml
│   │   ├── config/
│   │   │   ├── cluster-config.yaml        # ConfigMap with env-specific values
│   │   │   └── cluster-secrets.enc.yaml   # SOPS-encrypted Secret
│   │   └── cluster.yaml                   # All Flux Kustomizations with DAG
│   ├── memphis/
│   │   └── (same structure)
│   └── abydos/
│       └── (same structure)
└── infra/                                 # Terraform (unchanged)
```

---

## The `cluster.yaml` Wiring

This is where you define the full dependency DAG per cluster. Each Flux Kustomization points to a `_lib/` path and shares the same `postBuild` config:

```yaml
# clusters/horus/cluster.yaml
---
# Layer 0: Cluster config (must exist before anything else)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/horus/config
  prune: false                             # never prune config
  sourceRef:
    kind: GitRepository
    name: flux-system
  decryption:
    provider: sops
    secretRef:
      name: sops-age
---
# Layer 1: Controllers
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: controllers
  namespace: flux-system
spec:
  dependsOn:
    - name: cluster-config
  interval: 30m
  path: ./_lib/controllers
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
      - kind: Secret
        name: cluster-secrets
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cert-manager
      namespace: cert-manager
    - apiVersion: apps/v1
      kind: Deployment
      name: external-secrets
      namespace: external-secrets
---
# Layer 2: Infrastructure (depends on controllers)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: flux-system
spec:
  dependsOn:
    - name: controllers
  interval: 30m
  path: ./_lib/infrastructure
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
      - kind: Secret
        name: cluster-secrets
---
# Layer 3: Security (depends on controllers, parallel to infra)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: security
  namespace: flux-system
spec:
  dependsOn:
    - name: controllers
  interval: 30m
  path: ./_lib/security
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
---
# Layer 4: Applications (depends on infra + security)
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: flux-system
spec:
  dependsOn:
    - name: infrastructure
    - name: security
  interval: 15m
  path: ./_lib/apps/wallabag/overlays/prod  # or use a top-level kustomization
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
      - kind: Secret
        name: cluster-secrets
```

### Choosing Between One Big Apps Kustomization vs Per-App

For your current scale (4 apps), a single `apps` Flux Kustomization pointing at a directory with a kustomize `kustomization.yaml` that lists all app overlays is simpler. If you later want per-app health gating (e.g., Wallabag depends on CNPG being healthy but FreshRSS doesn't), you can split into per-app Flux Kustomizations at that point. Start simple, split when you need it.

---

## Bootstrap Integration

Your Terraform v3.1.0 module already handles flux bootstrap with the `flux_config` variable pointing to `clusters/abydos`. The only addition needed is seeding the cluster ConfigMap and Secret before Flux starts reconciling. You can either:

1. Add the ConfigMap/Secret creation to the Terraform module as a `kubernetes_manifest` resource (runs after bootstrap, before first reconciliation)
2. Include it in the bootstrap script alongside the SOPS age key creation (the pattern you already use)

Option 2 is simpler and keeps the bootstrap script as the single source of truth for cluster initialization:

```bash
flux-deploy() {
  # SOPS key (existing)
  cat ~/.local/flux-staging.agekey | kubectl create secret generic sops-age \
    --namespace=flux-system --from-file=flux-staging.agekey=/dev/stdin

  # Cluster config (new)
  kubectl apply -f clusters/horus/config/cluster-config.yaml

  # Cluster secrets (new - decrypt and apply)
  sops -d clusters/horus/config/cluster-secrets.enc.yaml | kubectl apply -f -

  # Flux bootstrap (existing)
  flux bootstrap git \
    --url=ssh://git@github.com/alexrf45/home-0ps.com.git \
    --path=clusters/horus \
    --private-key-file=/home/fr3d/.ssh/fr3d \
    --branch main --force
}
```

---

## Migration Execution Summary

1. **Build `_lib/` from `infrastructure/`**: Move the better-quality manifests from `infrastructure/controllers/base/` into `_lib/controllers/`, parameterize environment-specific values with `${VAR}` placeholders
2. **Create `cluster-config` ConfigMaps**: One per cluster with all environment-specific values (hostnames, IPs, storage classes, gateway names, issuer names)
3. **Write the `cluster.yaml` DAG**: Per cluster, with proper `dependsOn` chains and `postBuild.substituteFrom`
4. **Test on abydos first**: Change the Flux bootstrap path, seed the ConfigMap, watch reconciliation
5. **Promote to memphis, then horus**
6. **Delete old structure**: Remove `controllers/`, `applications/`, `components/` once all clusters are migrated
7. **Update Renovate `includePaths`**: Point at the new `_lib/` paths
