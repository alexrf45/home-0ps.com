# ADR-0003: Single-instance CNPG on static iSCSI zvols + CSI VolumeSnapshots

- **Status:** Accepted (core direction). Partially executed — zvols created and dead Terraform S3/R2 destroyed per operator annotations; snapshot infrastructure and the CNPG cutover are **not yet built**.
- **Date:** 2026-05-20
- **Deciders:** fr3d
- **Supersedes:** [ADR-0002](0002-object-storage-r2.md) **for the CNPG backup path only** (the object-storage module stays as a generic capability).

## Context

Two coupled problems with the data tier:

1. **CNPG runs on `local-path`.** Both live clusters (`authentik-*`, `freshrss-*`) use node-local hostpath storage (`instances: 3`, 5Gi data + 2Gi WAL each). A rescheduled Postgres pod does not find its data on the new node — a latent resilience bug.
2. **Backups depend on off-site object storage.** Authentik archives WAL+base to R2 via Barman; FreshRSS has **no backup at all**. Recovery for the one backed-up DB requires pulling data down from R2.

Operator's stated model: *"define my storage once, deploy the DB to it, tear the app down at will and point it back at the volumes — data should not have to come down from an S3 bucket."* That is a **static-volume, local-durability** model, the opposite of `local-path` + Barman/R2.

## Decision

For every CNPG database:

1. **`instances: 1`** — drop in-cluster streaming HA; TrueNAS (ZFS RAID) is durability, ZFS/CSI snapshots are recovery.
2. **One pre-created TrueNAS zvol per DB**, WAL folded into PGDATA (drop `walStorage`) → one zvol = one PV = one PVC.
3. **Static PV, `reclaimPolicy: Retain`,** bound by CNPG via `pvcTemplate.volumeName` (mirrors the proven `dev-freshrss-pv` app-volume pattern).
4. **Backups via CSI VolumeSnapshots** (`ScheduledBackup method: volumeSnapshot`) through democratic-csi → ZFS. Recovery reads from a local ZFS snapshot, never S3.
5. **Retire R2/S3 from the backup path** — drop Authentik's Barman/R2 ObjectStore; destroy the dead wallabag S3 stack; destroy the Authentik R2 bucket once snapshots are proven.

Targeting PostgreSQL 18 for new/migrated clusters going forward.

## Rationale

| Concern | Reasoning |
| --- | --- |
| Matches the mental model | With 1 instance there is exactly one zvol per DB — literally "define storage once." |
| HA was never load-bearing | One rack, one TrueNAS box — a 3-node quorum doesn't survive the failure domains that actually threaten the lab (NAS, rack, house). It only bought zero-downtime reschedules. |
| Durability in the right layer | ZFS RAID (disk failure) + ZFS snapshots (logical corruption / fat-finger) is stronger and more local than 3 ephemeral local-path copies. |
| Simpler teardown/redeploy | One CR, one PVC, one PV, one zvol — trivial to reason about. |

**Accepted trade-off:** brief downtime on pod restart, node failure, and Postgres minor upgrades (no standby). For SSO + RSS, minutes of unavailability (not data loss) is acceptable.

## Consequences

**Positive**
- "Tear down at will, point back at the volume" loop: soft-teardown (delete the `Cluster` CR only) → CNPG re-adopts the annotated PVC, no `initdb`, data intact.
- All data and recovery stay local; no egress, no off-site dependency for the common case.

**Negative / trade-offs**
- No automatic failover. A node hosting the single instance going down = downtime until reschedule + iSCSI re-attach.
- **Hard-teardown footgun:** deleting the PVC leaves the `Retain` PV `Released` (stale `claimRef.uid`) — recover via VolumeSnapshot `bootstrap.recovery` (preferred) or manual `claimRef` patch.
- **Do not** point `bootstrap.initdb` at a zvol that already holds PGDATA — `initdb` on non-empty storage fails/clobbers.

**Prerequisite (currently absent — blocks scheduled backups):**
- `external-snapshotter` CRDs → `global/crds/`; snapshot-controller → `storage` layer; CSI snapshotter sidecar in `_lib/storage/freenas-csi/helmrelease.yaml`; a `VolumeSnapshotClass freenas-iscsi-snapclass`.
- Verify `pvcTemplate.volumeName` is honored by the pinned operator (chart `0.27.0`/CRDs `1.28.0`) on a throwaway cluster first; fall back to PV `claimRef` pre-binding if not.

**Open question for the operator:** zero off-site backup (NAS loss = total loss) vs. a thin offsite DR backstop (periodic `zfs send` to B2, or a monthly Barman dump on R2). The decision assumes local-only; the backstop is a deliberate add-on.

## References

- Full decision essay (archived): `archive/source-docs/storage-strategy-decision.md`
- Storage guide + migration phases: [infra/storage.md](../infra/storage.md)
- Related memory: CNPG bootstrap is one-shot; CNPG recovery fresh-archiver path.
