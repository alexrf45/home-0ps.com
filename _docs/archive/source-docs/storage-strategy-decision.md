# Storage strategy — self-hosted CNPG persistence + object-storage exit

**Status:** Decided (core direction). Single Postgres instance on a single
pre-created TrueNAS zvol per database; CNPG backups move from Barman→R2 to
CSI VolumeSnapshots (ZFS snapshots on TrueNAS). R2/S3 are retired from the
backup path.
**Date:** 2026-05-20
**Author:** fr3d (with Claude)
**Supersedes (partially):** `_docs/object-storage-r2-vs-s3-decision.md` — the
reusable `terraform/modules/object-storage/` module stays in the repo as a
generic capability, but R2 is no longer the CNPG backup backend. See
"Relationship to the R2 decision" below.

## Problem

Two coupled issues with the current data tier:

1. **CNPG runs on `local-path`.** Both live Postgres clusters —
   `authentik-${ENVIRONMENT}-cluster` and `freshrss-${ENVIRONMENT}-cluster` —
   use `storageClass: local-path` (node-local hostpath at `/var/data`, 5Gi
   data + 2Gi WAL each, `instances: 3`). Node-local storage means a rescheduled
   Postgres pod does not find its data on the new node. This is a latent
   resilience bug, not just an aesthetic one.

2. **Backups depend on off-site object storage.** Authentik's CNPG cluster
   archives WAL + base backups to Cloudflare **R2** via the Barman-Cloud
   plugin (`ObjectStore authentik-dev-cluster-2026`). freshrss has **no backup
   at all**. The recovery story for the one DB that is backed up requires
   pulling data back down from R2.

The operator's stated preference: _"I'd rather define my storage once, deploy
the DB to it, and tear the app down at will and point it back to the volumes
each time. My data should not have to come down from an S3 bucket."_

That is fundamentally a **static-volume** model with **local** durability and
recovery — which `local-path` + Barman/R2 is the opposite of.

## Decision

For every CNPG database in the lab:

1. **`instances: 1`.** Single Postgres instance. In-cluster streaming HA is
   dropped; TrueNAS (ZFS RAID) is the durability layer and ZFS/CSI snapshots
   are the recovery layer.
2. **One pre-created TrueNAS zvol per database.** WAL lives inside the main
   PGDATA volume (drop the separate `walStorage`), so each DB maps to exactly
   **one zvol = one PV = one PVC**. **_zvols have been created_**
3. **Static PV, `reclaimPolicy: Retain`, bound by CNPG via `pvcTemplate`.**
   The volume is defined once (zvol + PV manifest checked into the repo). CNPG
   binds its single instance PVC to that PV.
4. **Backups via CSI VolumeSnapshots, not object storage.** CNPG
   `ScheduledBackup` with `method: volumeSnapshot` snapshots the iSCSI volume
   through democratic-csi → ZFS. Recovery reads from a local ZFS snapshot, never
   from S3.
5. **Retire R2/S3 from the backup path.** Drop the Authentik Barman/R2
   `ObjectStore`; `terraform destroy` the dead wallabag AWS S3 stack; destroy
   the Authentik R2 bucket once VolumeSnapshot backups are proven. **_terraform resources have been destroyed_**

## Why single-instance is the right call here

| Concern                                 | Reasoning                                                                                                                                                                                                                                              |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Matches the mental model**            | CNPG owns one PVC per replica (`<cluster>-N`). With 3 instances, "define storage once" really means "define 3 zvols and pre-bind each to its replica's PVC." With 1 instance there is exactly one zvol per DB — literally what the operator asked for. |
| **HA was never load-bearing here**      | This is a single Proxmox rack, one TrueNAS box. A 3-node Postgres quorum doesn't survive the failure domains that actually threaten the lab (the NAS, the rack, the house). It mostly bought zero-downtime pod reschedules.                            |
| **Durability moves to the right layer** | ZFS RAID protects against disk failure; ZFS snapshots protect against logical corruption / fat-finger. That is a stronger and more local guarantee than 3 ephemeral local-path copies.                                                                 |
| **Simpler teardown/redeploy**           | One CR, one PVC, one PV, one zvol. The "tear down and re-point" loop is trivial to reason about (see workflow below).                                                                                                                                  |

**Accepted trade-off:** brief downtime during pod restarts, node failure, and
Postgres minor-version upgrades (no standby to fail over to). For Authentik
(SSO) and freshrss this is acceptable — minutes of unavailability, not data
loss.

## What it looks like

### 1. Pre-created zvols (TrueNAS, one-time per DB)

Created under the existing iSCSI dataset parent
`home-share/iscsi/k8s/dev/volumes` (`DATASET_PARENT` in `cluster-config`),
exposed as iSCSI targets on `192.168.20.106:3260`. Naming mirrors the proven
freshrss-app pattern (`dev-freshrss-pv` → zvol `dev-freshrss-pvc`):

| Database  | zvol / volumeHandle | IQN                                            | Size |
| --------- | ------------------- | ---------------------------------------------- | ---- |
| authentik | `dev-authentik-db`  | `iqn.2005-10.org.freenas.ctl:dev-authentik-db` | 10Gi |
| freshrss  | `dev-freshrss-db`   | `iqn.2005-10.org.freenas.ctl:dev-freshrss-db`  | 10Gi |

(Sizes bumped from 5Gi to fold WAL in. Tune to taste; `allowVolumeExpansion`
is on.)

### 2. Static PersistentVolume (checked into the overlay)

Same shape as `_lib/applications/freshrss/overlays/dev/volume.yaml`, but for the
DB zvol. `Retain` so it survives PVC/cluster deletion:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: dev-authentik-db-pv
  labels: { app: authentik, role: database, persistent: "true" }
spec:
  capacity: { storage: 10Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: iscsi
  csi:
    driver: freenas-api-iscsi
    fsType: ext4
    volumeHandle: dev-authentik-db # must match the TrueNAS zvol name
    volumeAttributes:
      lun: "0"
      node_attach_driver: iscsi
      provisioner_driver: freenas-api-iscsi
      portal: "192.168.20.106:3260"
      iqn: "iqn.2005-10.org.freenas.ctl:dev-authentik-db"
```

### 3. CNPG Cluster binding to the static PV

Single instance, no separate `walStorage`, `pvcTemplate.volumeName` pins the
one PVC (`<cluster>-1`) to the static PV:

**_update cnpg cluster postgresl version to 18 moving forward_**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-${ENVIRONMENT}-cluster
  namespace: authentik
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4-6@sha256:...
  bootstrap:
    initdb:
      { database: authentik, owner: authentik, secret: { name: authentik-env } }
  storage:
    size: 10Gi
    pvcTemplate:
      accessModes: [ReadWriteOnce]
      storageClassName: iscsi
      resources: { requests: { storage: 10Gi } }
      volumeName: dev-authentik-db-pv # explicit static bind
  # NOTE: no walStorage — WAL stays inside PGDATA (one volume per DB)
```

> **Version check:** confirm `spec.storage.pvcTemplate.volumeName` is honored by
> the pinned operator (`cloudnative-pg` chart `0.27.0`, CRDs `1.28.0`) before
> rolling out — validate on a throwaway cluster first. If `volumeName` is
> ignored, fall back to pre-binding the PV's `claimRef` to the exact PVC name
> CNPG generates (`<cluster>-1`).

### 4. Backups — CSI VolumeSnapshots (replaces Barman/R2)

```yaml
spec:
  backup:
    volumeSnapshot:
      className: freenas-iscsi-snapclass
      snapshotOwnerReference: cluster
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: authentik-dev-snap }
spec:
  schedule: "0 0 2 * * *"
  method: volumeSnapshot
  cluster: { name: authentik-${ENVIRONMENT}-cluster }
```

Restore is `bootstrap.recovery` from a `volumeSnapshot` source — all local to
TrueNAS, no object storage involved.

## The teardown / re-point workflow (what the operator asked for)

- **Soft teardown (the normal case): delete the `Cluster` CR only.** CNPG does
  **not** garbage-collect instance PVCs on cluster deletion (consistent with
  the existing "CNPG bootstrap is one-shot" runbook — PVCs are deleted by hand
  when you _want_ a fresh start). The PVC keeps its CNPG annotations; the PV and
  zvol persist. Re-apply the same `Cluster` manifest → CNPG **re-adopts** the
  existing PVC and starts Postgres on the existing PGDATA — **no `initdb`,
  data intact.** This is the "tear down at will, point back at the volume" loop.

- **Hard teardown (you also deleted the PVC):** the `Retain` PV goes to
  `Released` and won't auto-rebind (stale `claimRef.uid`). Two ways back:
  1. **Preferred:** recreate from a VolumeSnapshot via `bootstrap.recovery`
     (clean, what the snapshot schedule is for).
  2. Manually `kubectl patch` the PV to clear `spec.claimRef`, then let CNPG
     recreate the PVC bound to it. Fiddly — document but avoid.

> ⚠️ **Do not** recreate a `Cluster` with `bootstrap.initdb` pointing (via a
> brand-new PVC) at a zvol that already holds PGDATA — `initdb` on non-empty
> storage fails or clobbers. Either keep the annotated PVC (soft teardown) or
> use snapshot recovery (hard teardown).

## Migrating the existing data (no S3 involved)

Both DBs currently hold live data on `local-path`. Move it locally:

1. **Stand up snapshot infrastructure** (prerequisite — see below).
2. **Clone onto iSCSI via `bootstrap.pg_basebackup`.** Create the new
   single-instance iSCSI cluster with `bootstrap.pg_basebackup` sourcing the
   existing local-path cluster (live streaming clone, fully in-cluster). Verify,
   then cut the app's DB service over and delete the old cluster.
   - Fallback: `pg_dump` from old → `pg_restore` into new.
3. **Authentik specifically** could also `bootstrap.recovery` from its existing
   R2 backup — but `pg_basebackup` keeps even the migration off S3, so prefer it.
4. freshrss has no backup today, so `pg_basebackup`/`pg_dump` is the only path
   (its data is largely reconstructable RSS state if a clone is impractical).

## Prerequisite work (not yet in the repo)

CSI VolumeSnapshots need infrastructure that is currently **absent**:

- **`external-snapshotter` CRDs** (`VolumeSnapshot`, `VolumeSnapshotContent`,
  `VolumeSnapshotClass`) — add to `global/crds/` per the project CRD pattern.
- **snapshot-controller** deployment — add to the `storage` layer.
- **CSI snapshotter sidecar** enabled in the democratic-csi HelmRelease
  (`_lib/storage/freenas-csi/helmrelease.yaml`). The driver side already has
  `detachedSnapshotsDatasetParentName: ${DATASET_SNAPSHOTS}` configured.
- **A `VolumeSnapshotClass`** (`freenas-iscsi-snapclass`) referencing driver
  `freenas-api-iscsi`.

Until these land, the migration can proceed (static zvols + `pg_basebackup`),
but scheduled backups can't — so sequence snapshot infra **before** retiring R2.

## Companion cleanups

- **Fix the StorageClass reclaim default.** `cluster-config` sets
  `RECLAIM_POLICY: "Delete"` on the dynamic `iscsi` class — a footgun. Static
  PVs carry their own `Retain`, but flip the class default to `Retain` so any
  accidental dynamic volume also survives PVC deletion.
- **Destroy the dead wallabag AWS S3 stack** (`terraform/dev/wallabag-s3-backup/`)
  — app is gone, bucket + IAM are orphaned.
- **Destroy the Authentik R2 bucket** (`terraform/dev/authentik-object-storage/`)
  **only after** VolumeSnapshot backups are verified. (Reminder:
  `cloudflare_r2_bucket_lifecycle` can't be `terraform destroy`'d — manual
  dashboard cleanup.)

## Relationship to the R2 decision

`_docs/object-storage-r2-vs-s3-decision.md` chose R2 for CNPG backups on
2026-05-16. This document **reverses that for the CNPG backup path** in favor of
local CSI snapshots, driven by the privacy/self-hosting requirement ("data
shouldn't come from S3"). The reusable `terraform/modules/object-storage/`
module is **kept** — it's still the right tool if a _future_ workload genuinely
needs off-site object storage (e.g. an offsite DR copy, Loki archive, Velero).
The R2 decision doc should be marked **superseded for CNPG backups** with a
pointer here.

> Open question for the operator: do you want **zero** off-site backup (pure
> local snapshots — a NAS loss = total loss), or a thin **offsite DR** copy
> (e.g. periodic `zfs send` to Backblaze B2, or keep a _monthly_ Barman dump on
> R2) as a disaster backstop? The decision above assumes local-only; the offsite
> backstop is a deliberate add-on if you want it.

## Phased rollout

1. **Phase A — snapshot infra.** external-snapshotter CRDs + controller +
   snapshotter sidecar + `VolumeSnapshotClass`. Verify a manual VolumeSnapshot
   of an existing iSCSI PVC succeeds.
2. **Phase B — fix reclaim default** (`RECLAIM_POLICY: Retain`).
3. **Phase C — freshrss first (lower stakes).** Create zvol + static PV; new
   single-instance iSCSI cluster via `pg_basebackup`; cut over; delete old
   local-path cluster; add `ScheduledBackup`.
4. **Phase D — authentik.** Same pattern. Validate SSO + Grafana OIDC still work
   end-to-end after cutover.
5. **Phase E — retire object storage.** Remove the Authentik Barman/R2
   `ObjectStore` + plugin; `terraform destroy` wallabag S3; destroy Authentik R2
   bucket; supersede the R2 decision doc.

## Recommendation summary

Go single-instance, one static zvol per DB, CSI VolumeSnapshots for backup,
R2/S3 out of the CNPG path. It matches the operator's stated model exactly,
moves durability to ZFS where it belongs, and keeps all data and recovery
local. The only genuinely new build is the snapshot infrastructure (Phase A);
everything else reuses patterns already proven in the repo (static iSCSI PV from
freshrss-app, CNPG clusters from authentik/freshrss).
