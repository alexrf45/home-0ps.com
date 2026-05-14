# CryptPad — implementation plan

**Status:** Plan, ready to execute.
**Date:** 2026-05-14
**Target cluster:** dev (memphis); promotion to prod via the existing branch-promotion model.
**Reference:** [CryptPad install docs](https://docs.cryptpad.org/en/admin_guide/installation.html), [docker-cryptpad/cryptpad image](https://hub.docker.com/r/cryptpad/cryptpad).

## Goal

Deploy an end-to-end encrypted CryptPad instance for collaborative
notes/docs/spreadsheets — single replica, persistent storage on iSCSI,
exposed internally on `dev.int.cryptpad.home-0ps.com` and externally via
Cloudflare Tunnel once SSO is live.

## Why CryptPad

- Genuinely E2EE — keys never reach the server, so even a server compromise
  doesn't leak document content. Aligns with the lab's privacy stance.
- Workload exercises the **two-hostname constraint** (main + sandbox), which
  is a useful test of the Cilium Gateway's `hostnames` multi-routing and a
  good template for any future iframe-isolating app.
- Active upstream, regular CVE response, Docker image is maintained.

## Architectural constraints (read before designing)

### Two-domain isolation (NON-NEGOTIABLE)

CryptPad **must** be served on two distinct origins:

- `cryptpad.example.com` — main UI, app shell, API
- `sandbox.cryptpad.example.com` — sandboxed iframe content

Both terminate at the same backend container, but the browser MUST see them
as different origins for the encryption boundary to be enforced. Serving on
a single hostname will work superficially but breaks CSP and weakens the
security model — the upstream project considers this a misconfiguration.

This means **two HTTPRoutes** (main + sandbox) pointing at the **same
Service**, both fronted by the same Cilium Gateway listener. Both hostnames
must be in the wildcard TLS cert, which the existing
`*.home-0ps.com` certificate already covers.

### Single-replica only

CryptPad uses an in-memory store + on-disk blob store. Multi-replica
requires the CryptPad Enterprise clustering features (license-gated) or an
external Redis. Single replica + iSCSI PVC + healthchecks is fine for
homelab usage and matches the FreshRSS pattern.

### Storage

- `/cryptpad/data` — channels, pads, app state. **Hot path**, frequent
  small writes. iSCSI PVC (RWO), 20 Gi to start.
- `/cryptpad/blob` — uploaded file blobs. Larger objects, mostly write-once.
  Could go to a separate PVC; start in the same PVC and split later if size
  becomes a problem.
- `/cryptpad/customize` — branding/customization, ConfigMap-mounted
  (read-only); no PVC.
- `/cryptpad/block` — login-blocks; same PVC as `data`.

Total starting PVC: **20 Gi iSCSI**, expandable.

## Directory layout

```
_lib/applications/cryptpad/
├── base/
│   ├── configmap.yaml          ← config.js + customize/
│   ├── deployment.yaml
│   ├── external-secret.yaml    ← admin keys, OIDC client secret
│   ├── httproute-main.yaml     ← cryptpad.<domain>
│   ├── httproute-sandbox.yaml  ← sandbox.cryptpad.<domain>
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── pvc.yaml
│   └── service.yaml
└── overlays/dev/
    └── kustomization.yaml
```

## Manifests (sketches)

### `namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cryptpad
  labels:
    ${GATEWAY_NAME}: "true"
    pod-security.kubernetes.io/enforce: restricted
```

### `pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CRYPTPAD_DATA_PVC_NAME}
  namespace: cryptpad
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: iscsi
  resources:
    requests: { storage: 20Gi }
```

### `deployment.yaml`

- Image: `cryptpad/cryptpad:${CRYPTPAD_VERSION}` (e.g. `2026.x.x` — pin a
  release tag, let Renovate update).
- `replicas: 1`, `strategy: Recreate`.
- **SecurityContext:**
  - Pod: `fsGroup: 4001`, `seccompProfile: RuntimeDefault`.
  - Container: `runAsUser: 4001`, `runAsGroup: 4001`, `runAsNonRoot: true`,
    `readOnlyRootFilesystem: true`, drop all caps, no privilege escalation.
  - Recall the Kyverno `add-default-securitycontext` policy mutates
    `runAsUser → 65534` at the pod level; **set `runAsUser` explicitly on
    the container** (memory note: `project_kyverno_default_securitycontext`).
- **EmptyDirs** for any path the container must write that isn't a PVC:
  `/tmp`, `/cryptpad/customize.dist` if the image writes there.
- **Volume mounts:**
  - PVC → `/cryptpad/data`, `/cryptpad/blob`, `/cryptpad/block` (subPaths).
  - ConfigMap → `/cryptpad/config/config.js` (subPath, read-only).
  - ConfigMap → `/cryptpad/customize` (read-only, branding).
- **Probes:** HTTP GET `/api/config` on port 3000 for both liveness and
  readiness.
- **Resources:** `requests.cpu: 50m`, `requests.memory: 256Mi`,
  `limits.memory: 768Mi`. Node.js so memory limits matter — revisit after
  observing real usage.

### `service.yaml`

Single Service exposing port 3000 (CryptPad's HTTP) and 3003 (WebSocket).
ClusterIP. Both HTTPRoutes target this Service.

### `httproute-main.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cryptpad-main
  namespace: cryptpad
spec:
  parentRefs:
    - { name: ${GATEWAY_NAME}, namespace: networking }
  hostnames:
    - "${CRYPTPAD_SUBDOMAIN}.home-0ps.com"
  rules:
    - matches:
        - path: { type: PathPrefix, value: / }
      backendRefs:
        - { name: cryptpad, port: 3000 }
    - matches:
        - path: { type: PathPrefix, value: /cryptpad_websocket }
      backendRefs:
        - { name: cryptpad, port: 3003 }
```

### `httproute-sandbox.yaml`

Identical to `httproute-main` except `hostnames` is `${CRYPTPAD_SANDBOX_SUBDOMAIN}.home-0ps.com`.
Both routes terminate against the same Service.

### `configmap.yaml`

`config.js` is JavaScript, not YAML — mount it from a ConfigMap with the
contents as a literal. Key values:

```javascript
module.exports = {
  httpUnsafeOrigin:   'https://cryptpad.${DOMAIN}',
  httpSafeOrigin:     'https://sandbox.cryptpad.${DOMAIN}',
  httpAddress:        '::',
  httpPort:           3000,
  websocketPort:      3003,
  filePath:           '/cryptpad/data/datastore/',
  archivePath:        '/cryptpad/data/archive/',
  pinPath:            '/cryptpad/data/pins/',
  blobPath:           '/cryptpad/blob/',
  blockPath:          '/cryptpad/block/',
  taskPath:           '/cryptpad/data/tasks/',
  adminEmail:         'fr3d@home-0ps.com',
  adminKeys:          [process.env.CRYPTPAD_ADMIN_KEY],
};
```

`adminEmail` and `adminKeys` are wired through env vars sourced from the
ExternalSecret. `${DOMAIN}` substitutes at Flux reconcile time.

### `external-secret.yaml`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cryptpad-config
  namespace: cryptpad
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: onepassword-connect
    kind: ClusterSecretStore
  target:
    name: cryptpad-config
  data:
    - secretKey: CRYPTPAD_ADMIN_KEY
      remoteRef: { key: cryptpad, property: admin-key }
    # Reserved for the Authentik OIDC client secret added in Phase 3.
    # - secretKey: OIDC_CLIENT_SECRET
    #   remoteRef: { key: cryptpad, property: oidc-client-secret }
```

The CryptPad admin key is generated once (`node ./scripts/oauth/generateAdminKey.js`)
and stored in the 1Password `cryptpad` item.

## Cluster-config additions

Append to `_clusters/dev/config/cluster-configs.yaml`:

```yaml
CRYPTPAD_VERSION: "2026.x.x"
CRYPTPAD_SUBDOMAIN: "dev.int.cryptpad"
CRYPTPAD_SANDBOX_SUBDOMAIN: "dev.int.sandbox.cryptpad"
CRYPTPAD_DATA_PVC_NAME: "dev-cryptpad-data-pvc"
```

## Flux Kustomization

Append to `_clusters/dev/cluster.yaml`:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cryptpad
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
  path: ./_lib/applications/cryptpad/overlays/dev
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

## Phased rollout

1. **PR 1 — Internal-only deploy.**
   - Add `_lib/applications/cryptpad/` tree.
   - Add cluster-config keys, Flux Kustomization.
   - DNS via ExternalDNS (cluster issuer already serves the wildcard cert).
   - Validate registration → pad creation → file upload from the LAN.

2. **PR 2 — Persistence + backups.**
   - Confirm iSCSI PVC behavior under crash; document recovery
     (`/cryptpad/data` must be restored as a unit).
   - Add a CronJob that `tar`s `/cryptpad/data` + `/cryptpad/blob` nightly
     to the R2 backup bucket (same provider as the wallabag pattern; reuse
     the `aws-creds` Secret approach).

3. **PR 3 — SSO integration (post-Authentik).**
   - Register CryptPad as an Authentik OIDC client.
   - Add OIDC config block to `config.js` (CryptPad has SSO support in the
     admin manual; confirm OSS image includes it before relying on it).
   - If OIDC support is admin-only / non-functional on OSS, fall back to
     putting the admin panel behind forward-auth and leaving the user
     registration form open.

4. **PR 4 — Public exposure.**
   - Add `cryptpad.home-0ps.com` and `sandbox.cryptpad.home-0ps.com` to the
     Cloudflare Tunnel hostname list.
   - Confirm both hostnames load over the tunnel and the CSP boundary
     holds (browser dev tools: sandboxed pads load from sandbox origin).

## Risks / open items

- **Sandbox cookie/CSP weirdness** — verify that Cloudflare Tunnel does not
  rewrite the `Origin` header in a way that breaks the sandbox boundary.
  Test from a clean browser profile.
- **Single-replica downtime** during upgrades — fine for homelab, but
  flag in advance if anyone else is using it.
- **OSS vs Enterprise gating on SSO** — CryptPad has moved SSO behind a
  paid tier in the past; double-check current OSS state before Phase 3.
- **Memory cap calibration** — Node.js will happily consume past
  `requests.memory`. Watch for OOMKills on the dashboard
  (`PodOOMKilled` alert already covers this) and bump `limits.memory`
  if it lands there.
- **PVC growth** — file uploads land in `/cryptpad/blob`. Set up a
  Prometheus rule on `kubelet_volume_stats_used_bytes` for the cryptpad PVC
  hitting 80% so we get warned before it fills.
