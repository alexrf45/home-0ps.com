# App guide: FreshRSS (RSS/Atom aggregator)

**Role:** Self-hosted feed reader. Internal at `dev.int.freshrss.home-0ps.com`.
**Status:** Live on dev (`memphis`). CNPG-backed, form-login (native OIDC planned per [ADR-0001](../decisions/0001-sso-authentik.md)).
**No standalone source doc existed** — this guide is written from the manifests.

---

## At a glance

| | |
| --- | --- |
| Image | `freshrss/freshrss:${FRESHRSS_VERSION}` (`1.27.0-alpine`) |
| Topology | 1 replica, `strategy: Recreate` (RWO data volume) |
| App data | static iSCSI PV `dev-freshrss-pv` (2Gi, `Retain`) ← the proven static-volume pattern |
| Database | CNPG `freshrss-dev-cluster`, 3 instances, local-path (5Gi + 2Gi WAL), PG 17.4, pgaudit on |
| Secrets | `freshrss-db-creds` via ESO ← 1Password `freshrss_dev` |
| Ingress | HTTPRoute `${FRESHRSS_SUBDOMAIN}.home-0ps.com` → :80 |
| Flux Kustomization | `freshrss` (top-level) |

## Where it lives

| Path | What |
| --- | --- |
| `_lib/applications/freshrss/base/deployment.yaml` | init-container + main container (see hardening below) |
| `_lib/applications/freshrss/base/secrets.yaml` | `freshrss-db-creds` ExternalSecret |
| `_lib/applications/freshrss/base/init-script-configmap.yaml` | custom `bootstrap.sh` mounted at `/opt/freshrss-init` |
| `_lib/applications/freshrss/base/{service,httproute,namespace,pvc}.yaml` | service/route/ns/(local-path PVC, unused in dev) |
| `_lib/applications/freshrss/overlays/dev/volume.yaml` | static iSCSI PV+PVC `dev-freshrss-pv`/`-pvc` (the active data volume) |
| `_lib/applications/freshrss/overlays/dev/database.yaml` | CNPG `Cluster` |
| `_lib/security/cilium-network-policies/freshrss-{default-deny,allow,cnpg-allow}.yaml` | network policy |
| `_clusters/dev/config/cluster-configs.yaml` | `FRESHRSS_VERSION`, `FRESHRSS_SUBDOMAIN`, `FRESHRSS_PVC_NAME: dev-freshrss-pvc` |

## The securityContext and writable-paths pattern

FreshRSS's Alpine entrypoint expects to run as root (writes `/etc/php84/php.ini`, seeds `Docker/`), but the main container runs as **apache (UID 100, GID 82)**. The fix enumerates *every* writable path in one pass:

- An **init container `seed-writable-dirs`** runs as root with only `CHOWN`/`DAC_OVERRIDE`/`FOWNER` (and `readOnlyRootFilesystem: true`). It copies `/etc/php84` and the `Docker/` dir into `emptyDir`s, `chown`s them `100:82`, and pre-`chown`s the persistent data volume so the unprivileged main container can write it.
- The **main container** runs `runAsUser: 100`, `runAsGroup: 82`, `fsGroup: 82`, drops ALL caps, adds only `NET_BIND_SERVICE`, seccomp `RuntimeDefault`.
- Writable mounts are explicit `emptyDir`s: `/etc/php84`, `/var/www/FreshRSS/Docker`, `/var/www/FreshRSS/extensions`, `/tmp`, `/run`; plus the data PVC at `/var/www/FreshRSS/data`.

This is the lab's reference example for "non-root app with a root-assuming entrypoint" — see [guides/best-practices.md](../guides/best-practices.md#permissions--writable-paths).

## Config & secrets

DB + admin credentials come from one 1Password item `freshrss_dev` → `freshrss-db-creds` Secret, injected as env (`DB_HOST/BASE/USER/PASSWORD`, `ADMIN_USER/PASSWORD/EMAIL`). Fields: `username`, `password`, `database`, `host` (`freshrss-dev-cluster-rw.freshrss.svc.cluster.local`), `port` (`5432`), `admin_user`, `admin_password`, `admin_email`. Probes hit `/i/?c=index&a=index` (liveness 30s delay, readiness 10s).

## Day-2 / operations

- **Upgrades:** bump `FRESHRSS_VERSION` (Renovate-driven); Flux reconciles, `Recreate` swaps the pod.
- **Restart:** `kube dev -n freshrss rollout restart deploy/freshrss`.
- **DB status:** `k8sop dev kubectl-cnpg status freshrss-dev-cluster -n freshrss`.

## Troubleshooting

| Symptom | First check | Likely fix |
| --- | --- | --- |
| Pod stuck Init | init-container logs | data PVC unbound or wrong ownership — confirm `dev-freshrss-pvc` is `Bound` |
| 500 / DB errors | `freshrss-db-creds` synced? CNPG healthy? | `get externalsecret -n freshrss`; `kubectl-cnpg status` |
| New pod hangs on rollout | RWO volume held by old pod | `Recreate` strategy is set; if stuck, delete the old pod |
| NXDOMAIN on hostname | ExternalDNS + CoreDNS split-horizon | see [infra/dns.md](../infra/dns.md) |

## Known gaps & follow-ups

- **CNPG DB has no backup** (S-5) — resolved naturally by the [ADR-0003](../decisions/0003-cnpg-local-snapshots.md) migration to single-instance iSCSI + CSI VolumeSnapshots. Until then the feed DB is unprotected (largely reconstructable RSS state).
- **No PodDisruptionBudget (R-1)** and **no `terminationGracePeriodSeconds` (R-7)** — add a PDB (`maxUnavailable: 1`) and 30–60s grace so the request finishes before SIGKILL. This is the first target of the resilience sprint.
- **No namespace ResourceQuota/LimitRange (H-4).**
- **Native OIDC not wired** — form-login today; the Authentik provider/application/entitlement pattern from [apps/authentik.md](authentik.md#wiring-an-oidc-consumer-grafana-pattern) applies (FreshRSS OIDC via `OIDC_*` env vars).
- `base/pvc.yaml` (`freshrss-data`, local-path 5Gi) is superseded by the overlay's iSCSI volume — candidate for cleanup.
