# Hetzner Cloud Deployment (cloud-ops)

## Overview

The `cloud-ops` branch is the canonical deployment target for the Hetzner Cloud cluster.
Infrastructure is provisioned by Terraform (Phase 1) and Flux GitOps is bootstrapped by a
separate CI job (Phase 2). This split ensures that a cluster health check gates Flux bootstrap,
and that `terraform plan` never fails due to missing cluster credentials.

## Cost Breakdown

| Resource | Type | Cost/mo |
|---|---|---|
| Control plane | cpx21 (2 vCPU, 4 GB) | ~$9 |
| Worker | cpx31 (4 vCPU, 8 GB) | ~$18 |
| Load balancer | lb11 | ~$6 |
| **Total** | | **~$33** |

Headroom: ~$17/mo available for Hetzner block storage volumes.

## Two-Phase Deploy

### Phase 1 — `terraform` job

Triggered on push to `cloud-ops` when `terraform/hetzner/**`, `_clusters/hetzner/**`, or `_lib/**` changes.

1. Decrypts `terraform.tfvars.enc` (SOPS Age key from `SOPS_AGE_KEY` secret)
2. Restores kubeconfig from Terraform state (no-op on fresh cluster)
3. `terraform plan` + `terraform apply`
   - Provisions Talos nodes (cpx21 CP + cpx31 worker) via `talos-hcloud-v1.0.0` module
   - Creates Cilium (Helm, Talos-compatible: `k8sServiceHost=127.0.0.1`, `k8sServicePort=7445`)
   - Creates `sops-age` secret in `flux-system` (Age key from 1Password)
   - Creates `hcloud` secret in `kube-system` (for hcloud-ccm and hcloud-csi)
   - Runs `flux install` + waits for Kustomization CRD + verifies DNS can reach `github.com`
4. `kubectl wait --for=condition=Ready nodes --all` — final health gate

### Phase 2 — `flux-bootstrap` job

Runs after Phase 1 succeeds (or on manual re-run with `skip_terraform=true`).

1. Restores kubeconfig from Terraform state
2. Guards: `kubectl wait --for=condition=Ready nodes --all --timeout=2m`
3. `flux bootstrap git --url=... --branch=cloud-ops --path=_clusters/hetzner --token-auth`
   - Uses `FLUX_GITHUB_TOKEN` secret (GitHub PAT with `repo` scope)
4. `flux wait kustomization --all --timeout=15m`

### Manual re-run (Phase 2 only)

If the cluster is already up but Flux needs to be re-bootstrapped:

```
Actions → Hetzner Cloud Deploy → Run workflow → skip_terraform: true
```

## Flux Dependency Chain

```
cluster-config
└── crds (prometheus-op CRDs, cnpg CRDs)
    └── controllers (cert-manager, cnpg, kyverno, mariadb-op,
        │            redis-op, renovate, hcloud-ccm)
        ├── pki (internal CA, trust-manager, trust-bundle)
        │   └── external-secrets-operator
        │       └── secrets (1password-connect, ClusterSecretStore)
        │           ├── networking (cilium-gateway, tailscale, clusterissuers)
        │           ├── dns (external-dns → Cloudflare)
        │           └── storage (hetzner-csi, barman-cloud)
        │               └── applications (wallabag hetzner overlay)
        └── security (cilium netpols, kyverno policies)
```

Defined in `_clusters/hetzner/cluster.yaml`. Each layer has `dependsOn` the previous.

## Required GitHub Secrets

| Secret | Purpose |
|---|---|
| `AWS_ACCESS_KEY_ID` | Terraform S3 backend (state) |
| `AWS_SECRET_ACCESS_KEY` | Terraform S3 backend (state) |
| `SOPS_AGE_KEY` | Decrypt `terraform.tfvars.enc` |
| `TF_BACKEND_CONFIG` | S3 backend config (bucket, region, key) |
| `FLUX_GITHUB_TOKEN` | GitHub PAT for `flux bootstrap git --token-auth` |
| `SLACK_BOT_TOKEN` | Slack deploy notifications |

GitHub variable: `SLACK_CHANNEL_ID`

## Troubleshooting

### Phase 1 failures

- **Talos bootstrap timeout**: Check Hetzner console — node may be in rescue mode. Re-run apply.
- **Cilium not ready**: `kubectl get pods -n networking` — check for crashlooping pods.
- **DNS health check fails**: CoreDNS may be blocked by Cilium policy.
  Check `kubectl logs -n kube-system -l k8s-app=kube-dns`.
- **`flux install` fails**: Usually a transient API timeout. Re-running apply will retry.

### Phase 2 failures

- **Auth error**: Verify `FLUX_GITHUB_TOKEN` has `repo` scope and is not expired.
- **Kustomization stuck**: `flux get kustomizations` to see which layer is blocked.
  `flux logs --follow` for controller details.
- **Secret decryption fails**: Verify the `sops-age` secret in `flux-system` matches
  the Age key referenced in `_clusters/hetzner/.sops.yaml`.
