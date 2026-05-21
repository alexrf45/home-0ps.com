# Infra guide: Storage

**Layer:** `storage` (Flux Kustomization, depends on `secrets`).
**Backing:** TrueNAS Scale @ `192.168.20.106` (ZFS). iSCSI block storage + node-local hostpath.
**Strategy direction:** [ADR-0003](../decisions/0003-cnpg-local-snapshots.md) (single-instance CNPG on static iSCSI + CSI snapshots), [ADR-0002](../decisions/0002-object-storage-r2.md) (R2 object-storage capability).

---

## What's deployed

| Component | Path | Notes |
| --- | --- | --- |
| democratic-csi (freenas-iscsi) | `_lib/storage/freenas-csi/` | chart `0.15.0`; driver `freenas-api-iscsi`; portal `192.168.20.106:3260`; creds via ESO |
| local-path-provisioner | `_lib/storage/local-path/` | node-local hostpath; **used by all CNPG clusters today** (the DR gap ADR-0003 fixes) |
| Barman Cloud plugin | `_lib/storage/barman-cloud/` | CNPG WAL/base archival to S3-compatible object storage |

StorageClasses & params come from the `cluster-config` ConfigMap: `STORAGE_CLASS_NAME: iscsi`, `DATASET_PARENT: home-share/iscsi/k8s/dev/volumes`, `DATASET_SNAPSHOTS: home-share/iscsi/k8s/dev/snapshots`, `RECLAIM_POLICY: "Delete"`.

## How volumes are used today

| Workload | Class | Notes |
| --- | --- | --- |
| FreshRSS app data | `iscsi` (static `dev-freshrss-pv`, `Retain`) | the reference static-volume pattern |
| Monitoring (Prometheus 50Gi, Tempo 30Gi, Grafana 5Gi, Alertmanager 5Gi) | `iscsi` (dynamic) | ~90Gi total |
| CNPG (authentik 3×5Gi+2Gi-wal, freshrss 3×5Gi+2Gi-wal) | `local-path` | **node-local — latent resilience bug** (ADR-0003) |

## The static iSCSI volume pattern

Pre-create a zvol on TrueNAS, check a static PV + PVC into the overlay, pin with `volumeName`. Reference: `_lib/applications/freshrss/overlays/dev/volume.yaml` —

- PV: `storageClassName: iscsi`, `persistentVolumeReclaimPolicy: Retain`, `csi.driver: freenas-api-iscsi`, `volumeHandle` = the zvol name, `iqn: iqn.2005-10.org.freenas.ctl:<name>`, `portal: 192.168.20.106:3260`.
- PVC: `volumeName: <pv>` for an explicit bind.

This is what [ADR-0003](../decisions/0003-cnpg-local-snapshots.md) extends to CNPG (one zvol per DB, bound via `pvcTemplate.volumeName`).

## Object storage (R2)

Reusable Terraform module `terraform/modules/object-storage/` (`backend = r2 | aws_s3`, default R2). Today's only consumer is the Authentik CNPG Barman backup (bucket `dev-authentik-e53522c0`). Per [ADR-0003](../decisions/0003-cnpg-local-snapshots.md) this is being retired from the CNPG path in favor of local snapshots; the module stays as a generic capability for a future genuine off-site need. Wiring + token rotation: `terraform/modules/object-storage/README.md`; [apps/authentik.md](../apps/authentik.md#recovery-and-day-2).

## Open items (storage tier)

| ID | Item | Action |
| --- | --- | --- |
| S-1 | Snapshot infra absent | Add `external-snapshotter` CRDs (→ `global/crds/`), snapshot-controller (→ `storage`), CSI snapshotter sidecar, `VolumeSnapshotClass freenas-iscsi-snapclass`. **Blocks scheduled backups.** Verify a manual snapshot first. |
| S-2 | CNPG → single static iSCSI zvol | Per-DB zvol + static `Retain` PV; `instances: 1`; drop `walStorage`; migrate via `bootstrap.pg_basebackup` (no S3). Verify `pvcTemplate.volumeName` honored by operator `0.27.0` on a throwaway first. |
| S-3 | Retire R2/S3 from CNPG | Drop Authentik Barman/R2 ObjectStore; `terraform destroy` wallabag S3; destroy Authentik R2 bucket (lifecycle rule needs manual dashboard cleanup). |
| S-4 | Reclaim default `Delete` | `cluster-configs.yaml:RECLAIM_POLICY` → `Retain` so accidental dynamic iSCSI volumes survive PVC deletion. |
| S-5 | FreshRSS DB unprotected | Resolved by S-2's VolumeSnapshot ScheduledBackup. |

## Gotchas

- **CNPG bootstrap is one-shot/immutable.** To retry a failed recovery: suspend Flux, delete the `Cluster` + instance PVCs, resume. CNPG does **not** GC instance PVCs on cluster deletion — that's what enables the soft-teardown / re-adopt loop.
- **CNPG recovery archiver path:** when promoting/restoring on object storage, the archiver `destinationPath` must point at a *new empty* prefix; recovery reads from the *old* prefix.
- Sequence S-1 (snapshot infra) **before** S-3 (retiring R2) — you can't lose the only backup before the replacement is proven.
