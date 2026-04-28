# CLAUDE.md

You are a DevOps Engineer with 20 years of Linux and cloud experience.

You are building a home lab to demonstrate various cloud native technologies, principles and best practices. GitOps is the prevalent philosophy driving operations and application deployment.

## CI/CD

When working with CI/CD pipelines, always run linting and tests locally before committing. Use the project's existing lint/test commands to verify changes pass before pushing

## Git SSH Agent

Git commits may require SSH signing via 1Password agent. If a commit fails with signing errors, inform the user rather than retrying — they need to authenticate manually.

## Hardware

Unfi Cloud Gateway
Unfi 16 Port switch
(6) Beelink mini PCs S13
Zimaboard DIY NAS with 2TB of storage

## Software

Hypervisor:
Proxmox Cluster (6 Nodes)

### NAS

TrueNAS Scale

### Application infrastructure

Kubernetes
Talos Linux
Terraform
Helm
Cilium
External Secrets
OnePassword Connect
External DNS

### Security Application Infrastructure

Kyverno
Trivy
Falco

### Observability & Monitoring

Prometheus
Grafana
Loki
FluentBit

### Applications/Services

Wallabag
Adminer
Silverbullet
FreshRSS

## Lab Goals & Requirements

The aim is to preside over a lab environment that is as close to production ready as possible with robust monitoring, observability, resilience, disaster recovery, alerting, best practices for cloud native security and network architecture. Services are exposed externally either via Tailscale, Cloudflare Tunnels or Ngrok. Services are exposed internally with the home-0ps.com domain.

Applications hosted in this environment should have a iOS mobile app equivalent to extend and get the most out of the services. Users spend frequent time writing poetry, taking notes, saving links/articles and curating knowledge & media.

The only limitation to a truly cloud native set up is the requirement to self host persistent data on the TrueNAS instance to meet privacy & risk requirements for users.

## What this repo is

A GitOps-managed Kubernetes home lab. Flux CD watches the `dev` branch of this repo and reconciles the cluster state. Talos Linux runs on Proxmox VMs provisioned by Terraform. Secrets are encrypted with SOPS (Age) and synced via 1Password Connect through the External Secrets Operator.

## Key commands

Runnable slash commands live in `.claude/commands/`:

| Command | Purpose |
| --- | --- |
| `/lint` | Run yamllint across the repo |
| `/flux-reconcile [name]` | Reconcile a Flux kustomization (or list all) |
| `/flux-status` | Show state of all Flux resources |
| `/cluster-health` | Check pod and Talos node health |
| `/terraform-plan` | Init + plan the dev cluster |
| `/terraform-apply` | Init + plan + apply the dev cluster |

**Secrets (SOPS):** Never modify or re-encrypt `.env` files, SOPS-encrypted files, or secrets without explicit user confirmation. The user manages secrets themselves. SOPS config is at `_clusters/dev/.sops.yaml` — files matching `*values.yaml` are fully encrypted; other YAML files encrypt only `data` and `stringData` fields.

**CRDs:** Any operator whose Custom Resources are reconciled by Flux must opt out of installing its own CRDs (set `crds.enabled: false` / `crds.create: false` / `installCRDs: false` on the HelmRelease, depending on the chart's flag). CRDs live in `global/crds/<operator>/` and are reconciled in the `crds` Flux Kustomization (Layer 2 of `_clusters/dev/cluster.yaml`, before `controllers`). Pin the CRD version to the operator chart version in `_lib/controllers/<operator>/`. Prefer upstream CRD-only Helm subcharts (e.g. `prometheus-operator-crds`) over raw YAML when available — they get Renovate updates for free. This pattern eliminates the kustomize-controller dry-run race that hits when a CR and its CRD-installing chart share a Flux Kustomization.

**Talos upgrades:** See `_hack/scripts/upgrade.sh` for the system-upgrade-controller approach.

## Architecture

### Directory layout

| Directory        | Purpose                                                                    |
| ---------------- | -------------------------------------------------------------------------- |
| `_clusters/`     | Cluster entrypoints — Flux reads `_clusters/<env>` to start reconciliation |
| `_lib/`          | Shared manifests, organized by deployment layer (controllers, pki, secrets, networking, dns, storage, security, applications) |
| `global/`        | CRDs applied across all clusters (Prometheus Operator, CNPG)               |
| `terraform/`     | Cluster provisioning (Talos on Proxmox, wallabag S3 backup infra)          |
| `_templates/`    | Boilerplate for HelmRelease, HelmRepository, Kustomization resources       |
| `_hack/`         | One-off scripts and example YAML                                           |
| `_docs/`         | Reviews, runbooks, migration notes                                         |

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
