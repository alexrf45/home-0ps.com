# Homer — implementation plan

**Status:** Plan, ready to execute.
**Date:** 2026-05-14
**Target cluster:** dev (memphis), promotion to prod follows existing branch-promotion model.
**Reference:** [bastienwirtz/homer](https://github.com/bastienwirtz/homer) — static dashboard, single binary, config from a single YAML file.

## Goal

Stand up Homer as the landing-page dashboard for home-0ps services. Internal
reachability on `dev.int.homer.home-0ps.com` from day one; external exposure
deferred until the SSO/Authentik phase from
[`sso-authentik-decision.md`](sso-authentik-decision.md) is live, then put
Homer behind a forward-auth outpost (it has no native auth).

## Why Homer (vs Heimdall, Dashy, Glance)

- Static SPA, config-as-YAML, no DB, no JS build pipeline. Fits GitOps —
  the entire dashboard state is a ConfigMap.
- Image is ~50 MB Alpine + nginx. Trivial resource footprint, friendly to a
  3-node Talos worker pool.
- Read-only at runtime; no auth needed inside the cluster because the
  dashboard does not modify state.

## Pattern fit

Homer matches the existing per-app Flux Kustomization pattern used by
freshrss/syncthing — separate top-level `homer` Kustomization in
`_clusters/dev/cluster.yaml`, base/overlay layout in `_lib/applications/homer/`.

## Directory layout

```
_lib/applications/homer/
├── base/
│   ├── configmap.yaml          ← Homer config.yml as a ConfigMap
│   ├── deployment.yaml         ← single replica, RO root FS
│   ├── httproute.yaml          ← dev.int.homer hostname
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   └── service.yaml
└── overlays/dev/
    └── kustomization.yaml      ← just `resources: [../../base]` for now
```

No secrets, no PVC, no database — Homer is stateless.

## Manifests (sketches)

### `namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: homer
  labels:
    ${GATEWAY_NAME}: "true"        # gateway allowedRoutes selector
    pod-security.kubernetes.io/enforce: restricted
```

### `deployment.yaml`

- Image: `b4bz/homer:v25.x` (pin to a digest in the HelmRelease via Renovate
  once we settle on it — Homer's tags are not OCI digests upstream, so
  Renovate `regex` manager will need a config entry).
- `replicas: 1`, `strategy: Recreate` — dashboard, no need for HA.
- `readOnlyRootFilesystem: true` with `emptyDir` mounts for `/run`,
  `/var/cache/nginx`, `/var/log/nginx`, and `/tmp` (nginx Alpine needs these
  writable; learned from FreshRSS).
- `runAsUser: 1000`, `runAsNonRoot: true`, `runAsGroup: 1000`.
- `seccompProfile: RuntimeDefault`, drop all caps.
- **Mount the config ConfigMap at `/www/assets/config.yml`** (the image's
  expected path). `readOnly: true`.
- Probes: HTTP GET `/` on port 8080, both liveness and readiness.
- Resources: `requests.cpu: 5m`, `requests.memory: 16Mi`,
  `limits.memory: 32Mi`. Static nginx — these are not stretches.

### `service.yaml`

ClusterIP, port 80 → targetPort 8080.

### `httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: homer-internal
  namespace: homer
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      namespace: networking
  hostnames:
    - "${HOMER_SUBDOMAIN}.home-0ps.com"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - { name: homer, port: 80 }
```

### `configmap.yaml`

Homer config rendered inline. Sections seed:

- **Self-hosted core** — FreshRSS, Syncthing, Adminer, Silverbullet.
- **Observability** — Grafana, Loki (Tailscale-exposed), Prometheus, Alertmanager.
- **Platform** — Flux UI (Capacitor), Kyverno reports, Falco UI if added.
- **Operator-only** — TrueNAS, Proxmox cluster web UI, UniFi controller.

Links use the `dev.int.*` hostnames so Homer works from the LAN today and
keeps working once the same hostnames flip to public via Cloudflare Tunnel.

## Cluster-config additions

Append to `_clusters/dev/config/cluster-configs.yaml`:

```yaml
HOMER_VERSION: "v25.x"             # pin after Renovate validates
HOMER_SUBDOMAIN: "dev.int.homer"
```

## Flux Kustomization

Append to `_clusters/dev/cluster.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: homer
  namespace: flux-system
spec:
  dependsOn:
    - name: dns
    - name: networking
    - name: security
  interval: 10m
  retryInterval: 1m
  timeout: 5m0s
  path: ./_lib/applications/homer/overlays/dev
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-config
```

No `storage`, no `secrets`, no `external-secrets-operator` dependency.

## Phased rollout

1. **PR 1 — Base deployment.**
   - Add `_lib/applications/homer/` tree.
   - Add `HOMER_VERSION` / `HOMER_SUBDOMAIN` to cluster-config.
   - Add Flux Kustomization to `_clusters/dev/cluster.yaml`.
   - Verify Homer answers on `dev.int.homer.home-0ps.com` from the LAN.

2. **PR 2 — Renovate config.**
   - Add a `regex` manager entry that watches `HOMER_VERSION` and the image
     tag in the Deployment. Without this Homer drifts behind upstream silently.

3. **PR 3 — Behind SSO (post-Authentik).**
   - Add `forward-auth` annotation / filter on the HTTPRoute referencing the
     Authentik proxy outpost.
   - Add an external `homer.home-0ps.com` HTTPRoute on the same Gateway,
     covered by the Cloudflare Tunnel.
   - Remove anonymous LAN access if desired (optional — internal-only access
     is fine to keep).

## Operations

- **Updating dashboard content** is a YAML edit on the ConfigMap; Flux
  reconciles, the running Pod re-reads (Homer reads the config at request
  time — no rollout needed).
- **Image upgrades** flow through Renovate PRs.
- **Backups** — none required. The dashboard is fully reconstructable from git.

## Risks / open items

- Homer's `b4bz/homer` image historically ran as root; current versions
  support `runAsUser` but need the writable paths above. Validate on the
  pinned tag before merging.
- Cloudflare Tunnel + forward-auth outpost is the same posture as Authentik
  itself; if the tunnel breaks, Homer is unreachable externally. Internal
  access stays via the Cilium Gateway regardless.
