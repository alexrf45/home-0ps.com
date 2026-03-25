# Self-Hosted Migration Guide (Proxmox / Talos)

## Overview

This guide documents the on-prem approach for migrating the cluster back to a self-hosted
environment on Proxmox VMs running Talos Linux. The `cloud-ops` branch targets Hetzner Cloud;
when ready to migrate, the `dev` branch targets the home cluster.

## Infrastructure

| Component | Cloud (cloud-ops) | On-prem (dev) |
|---|---|---|
| Provider | Hetzner Cloud | Proxmox VE |
| Terraform module | `terraform/hetzner/talos-hcloud-v1.0.0/` | `terraform/dev/talos-pve-v3.1.0/` |
| Storage | Hetzner CSI block volumes | FreeNAS iSCSI (democratic-csi) |
| Load balancer | Hetzner lb11 | Tailscale / HAProxy on Proxmox |
| Node images | `hcloud-talos/imager` provider snapshots | Talos ISO from factory |

## Cluster Config Differences

| Setting | Cloud | On-prem |
|---|---|---|
| Cluster entrypoint | `_clusters/hetzner/` | `_clusters/dev/` |
| Storage class | `hcloud-volumes` | `freenas-iscsi` |
| Gateway name | `hetzner-app-gateway` | varies |
| Falco | excluded | included |
| hcloud-ccm | included | excluded |

## Key Overlay Paths

The `_lib/` base/overlay pattern supports both environments:

```
_lib/
├── storage/
│   ├── hetzner/kustomization.yaml   # hetzner-csi + barman-cloud
│   └── dev/kustomization.yaml       # freenas-iscsi + local-path + barman-cloud
├── networking/
│   ├── hetzner/kustomization.yaml   # gateway + tailscale + clusterissuers
│   └── dev/kustomization.yaml       # gateway + tailscale + clusterissuers
├── controllers/
│   ├── hetzner/kustomization.yaml   # no Falco, hcloud-ccm included
│   └── dev/kustomization.yaml       # Falco included, no hcloud-ccm
└── applications/wallabag/
    ├── overlays/hetzner/            # CNPG + Barman to Hetzner object storage
    └── overlays/dev/                # CNPG + Barman to FreeNAS S3
```

## Migration Steps

1. **Provision Proxmox VMs** via `terraform/dev/`:
   ```bash
   cd terraform/dev
   terraform init -backend-config="remote.tfbackend" -upgrade
   terraform plan
   terraform apply --auto-approve
   ```

2. **Verify SOPS config** — `_clusters/dev/.sops.yaml` must reference the correct Age public key.

3. **Update DNS** — point dev subdomains to the on-prem load balancer IP or Tailscale exit node.

4. **Bootstrap Flux** against the `dev` branch:
   ```bash
   flux bootstrap git \
     --url=https://github.com/alexrf45/home-0ps.com.git \
     --branch=dev \
     --path=_clusters/dev \
     --token-auth
   ```

5. **Verify layers** — `flux get kustomizations` should show all layers Applied/True.
   Key controllers: cert-manager, cnpg, ESO, Tailscale, democratic-csi.

6. **Migrate wallabag data** — Barman backups can be restored to the new CNPG cluster
   via the recovery overlay in `_lib/applications/wallabag/overlays/dev/`.

## Notes

- The `dev` cluster uses FreeNAS iSCSI for RWO volumes and local-path for scratch.
  The Hetzner cluster uses Hetzner CSI block volumes — not directly compatible.
- Tailscale is the primary access method in both environments. Operator and ProxyGroup
  manifests are shared in `_lib/networking/tailscale/`.
- When ready to tear down Hetzner, run `terraform destroy` via the manual workflow trigger,
  then archive the `cloud-ops` branch.
