# syncthing — archived 2026-05-15

Syncthing was spun down in favor of CryptPad for the lab's collaborative
notes/document workflow. CryptPad is not a 1:1 functional replacement (it
is a collaborative-document app, not a file-sync engine), so this archive
captures the manifests for historical reference only — there is no
"restore to syncthing later" intent.

## What Flux pruned

The Flux Kustomization was removed from `_clusters/dev/cluster.yaml`,
which caused Flux to prune the in-cluster resources:

- StatefulSet `syncthing`, Services `syncthing` (ClusterIP) and
  `syncthing-sync` (LoadBalancer 192.168.20.227)
- HTTPRoute `syncthing-internal`
- PVCs `dev-syncthing-config-pvc` (2 Gi) and `dev-syncthing-data-pvc`
  (30 Gi)
- ExternalSecrets / Secrets in the `syncthing` namespace
- The `syncthing` namespace itself

## What was destroyed out-of-band

Unlike the wallabag spin-down (which retained the R2 backup bucket),
syncthing was torn down fully:

- The `dev-syncthing-config-pv` and `dev-syncthing-data-pv`
  PersistentVolumes were `kubectl delete`d after Flux finished pruning.
- The underlying TrueNAS iSCSI zvol datasets under
  `home-share/iscsi/k8s/dev/volumes/` were `zfs destroy`ed on the
  TrueNAS host (192.168.20.106).
- The data was confirmed migrated / backed up out-of-band before the
  teardown — there is no live restic snapshot from this lab pointing
  to a recoverable copy held by Claude tooling.

## What survives outside this archive

- The `_hack/scripts/syncthing-backup.sh` restic-to-anubis script and any
  existing snapshots on `anubis:/backups/syncthing-dev`. These are
  retained for one-off historical recovery but are no longer fed.
- Any iOS-side data that was syncing into the cluster.
- 1Password entries titled `syncthing_dev_*` — left in place; remove
  manually if you no longer want them.

## To restore (highly unlikely)

The on-disk data is gone, so a restore would mean re-bootstrapping a
fresh syncthing instance:

1. Move this `base/`+`overlays/` tree back under
   `_lib/applications/syncthing/`.
2. Re-add the Flux Kustomization to `_clusters/dev/cluster.yaml` and
   the `SYNCTHING_*` keys to `_clusters/dev/config/cluster-configs.yaml`.
3. Provision fresh iSCSI PVCs (the `StorageClass: iscsi` provisioner
   will create new datasets on TrueNAS).
4. Re-pair devices and re-seed data from the anubis restic backup if
   useful.
