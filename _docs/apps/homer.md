# App guide: Homer (dashboard)

**Role:** Static landing-page dashboard for lab services. Internal at `dev.int.homer.home-0ps.com`.
**Status:** Live on dev (`memphis`) since 2026-05-20. Stateless, config-as-YAML.
**Plan of record (archived):** `archive/source-docs/homer-implementation-plan.md`.

---

## At a glance

| | |
| --- | --- |
| Image | `b4bz/homer:${HOMER_VERSION}` (`v26.4.2`) — ~50 MB Alpine+nginx |
| Topology | 1 replica, `strategy: Recreate`; no DB, no PVC, no secrets |
| Config | a ConfigMap (`homer-config`) mounted at `/www/assets/config.yml` |
| Ingress | HTTPRoute `${HOMER_SUBDOMAIN}.home-0ps.com` → :8080 |
| Flux Kustomization | `homer` (top-level; `dependsOn` dns, networking, security only) |
| Notable | **First app with PSA `restricted` enforce** + per-container resource limits |

## Where it lives

| Path | What |
| --- | --- |
| `_lib/applications/homer/base/deployment.yaml` | single container, hardened securityContext |
| `_lib/applications/homer/base/configmap.yaml` | `config.yml` — the entire dashboard state |
| `_lib/applications/homer/base/{service,httproute,namespace}.yaml` | ClusterIP :8080, route, ns |
| `_lib/applications/homer/overlays/dev/kustomization.yaml` | `resources: [../../base]` |
| `_lib/security/cilium-network-policies/homer-{default-deny,allow}.yaml` | network policy (no CNPG allow — no DB) |
| `_clusters/dev/config/cluster-configs.yaml` | `HOMER_VERSION`, `HOMER_SUBDOMAIN: dev.int.homer` |

## Security posture

- Namespace enforces `pod-security.kubernetes.io/enforce: restricted` (and `warn`) — the pod spec satisfies it. This is the precedent to backfill onto freshrss/authentik.
- Pod + container: `runAsNonRoot`, `runAsUser/Group: 1000`, `fsGroup: 1000`, drop ALL caps, seccomp `RuntimeDefault`, `allowPrivilegeEscalation: false`.
- **`runAsUser` is set explicitly** because the Kyverno `add-default-securitycontext` policy mutates an unset `runAsUser` to `65534`, which wouldn't match the image's baked-in uid 1000. (Lab-wide gotcha — see [guides/best-practices.md](../guides/best-practices.md#kyverno-securitycontext-mutation).)
- Resources: requests `5m`/`16Mi`, limits `100m`/`32Mi`.
- **`readOnlyRootFilesystem: false` (deliberate for PR1)** — the entrypoint seeds theme assets into `/www/assets` on boot. Hardening to RO-rootfs is tracked as HM-1 (below).

## Operations

- **Update dashboard content:** edit `configmap.yaml` → Flux reconciles. Homer reads config at request time; no rollout needed for content changes.
- **Image upgrades:** bump `HOMER_VERSION` (Renovate). Homer's tags aren't OCI digests upstream, so Renovate needs a `regex`-manager entry to track it (PR2 in the plan — verify it's wired).
- **Backups:** none — fully reconstructable from git.

## Known follow-ups

- **HM-1 — read-only root FS.** Enumerate the writable paths the entrypoint needs (`/www/assets` theme seed, `/run`, `/var/cache/nginx`, `/var/log/nginx`, `/tmp` for Alpine nginx — same shape learned from FreshRSS), mount them as `emptyDir`, then flip `readOnlyRootFilesystem: true`.
- **HM-2 — tile content.** Confirm `config.yml` lists the live internal hosts (grafana, freshrss, authentik) so the dashboard is actually useful; extend as apps land.
- **Behind SSO (post-public-exposure).** Homer has no native auth — when externally exposed it must sit behind an Authentik forward-auth outpost ([ADR-0001](../decisions/0001-sso-authentik.md)). Internal LAN access via the gateway stays regardless.
