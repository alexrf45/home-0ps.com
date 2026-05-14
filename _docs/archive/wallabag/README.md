# wallabag — archived 2026-05-14

Wallabag was spun down in favor of the planned Thoth unified knowledge app.
The Flux Kustomization was removed from `_clusters/dev/cluster.yaml`, which
caused Flux to prune the in-cluster resources:

- Deployment, Service, HTTPRoute, Ingress in the `wallabag` namespace
- CNPG `Cluster wallabag-dev-cluster` + `ScheduledBackup` + Barman `ObjectStore`s
- The `wallabag` namespace itself
- ExternalSecret bindings to 1Password Connect

External state intentionally retained:

- Terraform module `terraform/dev/wallabag-s3-backup/` (R2 bucket + IAM)
  — left in place so the S3 archive remains readable for restoration.
- The Barman S3 archive itself in the bucket.

To restore: move this tree back under `_lib/applications/wallabag/`, re-add
the Flux Kustomization to `_clusters/dev/cluster.yaml`, and re-add
`WALLABAG_VERSION` / `WALLABAG_SUBDOMAIN` to `cluster-configs.yaml`. The
recovery overlay (`overlays/dev/database.yaml`) is already wired to bootstrap
from `wallabag-dev-cluster-backup`.
