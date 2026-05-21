# cryptpad — archived 2026-05-19 (cleanup completed 2026-05-20)

CryptPad was deployed as the Syncthing replacement for collaborative notes/docs,
and spun down shortly after — the replacement didn't stick. This archive holds
the manifests for historical reference only; there is no intent to restore.

## Timeline

- **2026-05-19** (`0b145f7`) — `cryptpad` Flux Kustomization removed from
  `_clusters/dev/cluster.yaml`; Flux pruned the in-cluster workload.
- **2026-05-20** (`cb18de6`) — cleanup finished: this manifest tree archived
  here, the four `CRYPTPAD_*` keys removed from `cluster-configs.yaml`, and the
  two `cryptpad-*` CiliumNetworkPolicies deleted. `grep cryptpad _lib _clusters
  terraform` is clean.

## What was pruned by Flux

- Deployment, Service, two HTTPRoutes (main + sandbox), PVC in the `cryptpad` namespace
- ExternalSecrets / Secrets in the namespace
- The `cryptpad` namespace itself

## Remaining manual step

- The TrueNAS zvol behind `dev-cryptpad-data-pvc` (20Gi) and any iSCSI target —
  **not verified destroyed.** Confirm with the operator before `zfs destroy`.

## Lesson (see ../../journey.md#retired-apps)

The spin-down was the **partial-cleanup anti-pattern**: removing the Flux
Kustomization first left the manifest tree, config keys, and CCNPs as dead config
for a day. Do spin-downs in one pass — remove the Kustomization *and* archive the
tree *and* strip config keys *and* delete policies together (the wallabag/syncthing
archives are the template).

## To restore (not intended)

Move this `base/`+`overlays/` tree back under `_lib/applications/cryptpad/`,
re-add the Flux Kustomization and `CRYPTPAD_*` keys, and re-create the CCNPs.
The on-NAS data is gone once the zvol is destroyed.
