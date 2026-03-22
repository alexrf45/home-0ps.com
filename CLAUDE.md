# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GitOps-managed Kubernetes home lab. Flux CD watches the `dev` branch of this repo and reconciles the cluster state. Talos Linux runs on Proxmox VMs provisioned by Terraform. Secrets are encrypted with SOPS (Age) and synced via 1Password Connect through the External Secrets Operator.

## Key commands

**Linting (CI runs this on all PRs and pushes to main):**
```bash
yamllint -c .yamllint.yaml .
```

**Flux reconciliation:**
```bash
flux reconcile kustomization <name> --with-source
flux get kustomizations
flux logs --follow
```

**Cluster access:**
```bash
kubectl get pods -A
talosctl health
```

**Terraform (dev cluster):**
```bash
cd terraform/dev
terraform init -backend-config="remote.tfbackend" -upgrade
terraform plan
terraform apply --auto-approve
```

**Encrypting secrets with SOPS:**
```bash
sops --encrypt --in-place <file>.yaml
```
SOPS config is at `_clusters/dev/.sops.yaml`. Files matching `*values.yaml` are fully encrypted; other YAML files encrypt only `data` and `stringData` fields.

**Talos node upgrades:**
```bash
# See _hack/scripts/upgrade.sh for the system-upgrade-controller approach
```

## Architecture

### Directory layout

| Directory | Purpose |
|---|---|
| `_clusters/` | Cluster entrypoints — Flux reads `_clusters/<env>` to start reconciliation |
| `_lib/` | Shared manifests, organized by deployment layer |
| `_applications/` | Standalone app manifests not yet integrated into `_lib/applications` |
| `global/` | CRDs applied across all clusters (Prometheus Operator, CNPG) |
| `terraform/` | Cluster provisioning (Talos on Proxmox, wallabag S3 backup infra) |
| `_templates/` | Boilerplate for HelmRelease, HelmRepository, Kustomization resources |
| `_hack/` | One-off scripts and example YAML |

### Flux reconciliation layers (dependency order)

Defined in `_clusters/dev/cluster.yaml`. Each layer depends on the one above it:

1. **cluster-config** — ConfigMap with environment variables (`ENVIRONMENT`, `CLUSTER_NAME`, hostnames, etc.) used by `postBuild.substituteFrom` in downstream Kustomizations
2. **crds** — Global CRDs from `global/crds/`
3. **controllers** — All operators: cert-manager, CloudNativePG, external-secrets, Falco, Kyverno, mariadb-operator, redis-operator, Renovate
4. **pki** — Internal CA keypair, trust-manager, trust bundle
5. **external-secrets-operator** — ESO deployment (depends on controllers + pki for mTLS)
6. **secrets** — 1Password Connect deployment + ClusterSecretStore
7. **networking** — Cilium Gateway, Tailscale operator, ClusterIssuers (Let's Encrypt via Cloudflare DNS-01)
8. **dns** — ExternalDNS (depends on secrets for Cloudflare API key)
9. **storage** — freenas-iscsi CSI, local-path provisioner, Barman Cloud
10. **security** — Cilium NetworkPolicies, Falco rules, Kyverno policies
11. **applications** — App workloads (currently only wallabag, using `_lib/applications/wallabag/overlays/dev`)

### Secrets flow

1Password secrets → 1Password Connect → External Secrets Operator → Kubernetes secrets

SOPS-encrypted secrets are decrypted by Flux using the `sops-age` secret in `flux-system`. The Age key comes from 1Password during bootstrap (see `terraform/dev/main.tf`).

### Application pattern

Apps in `_lib/applications/<app>/` follow kustomize base/overlay structure:
- `base/` — Deployment, Service, HTTPRoute/Ingress, Namespace, ExternalSecret definitions
- `overlays/<env>/` — Environment-specific patches (database config, object backup/recovery)

### Cluster config substitution

The `cluster-config` ConfigMap (at `_clusters/dev/config/cluster-configs.yaml`) provides variables like `${GATEWAY_NAME}`, `${WALLABAG_SUBDOMAIN}`, `${ENVIRONMENT}` that Flux substitutes into manifests at reconcile time via `postBuild.substituteFrom`.

## YAML conventions

- 2-space indentation
- Max line length 300 (Kubernetes manifests with long annotations/URLs)
- Multiple documents per file allowed (`---` separator)
- `document-start: disable` (leading `---` optional)
- `comments-indentation: disable` (Flux-generated files have inconsistent comment indentation)
