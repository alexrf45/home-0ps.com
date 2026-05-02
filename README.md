<div align="center">

<img src="https://avatars.githubusercontent.com/u/61287648?s=200&v=4" align="center" width="144px" height="144px" alt="kubernetes"/>

## home-0ps.com

![GitHub repo size](https://img.shields.io/github/repo-size/alexrf45/khepri) [![Static Badge](https://img.shields.io/badge/fr3d.dev-blue?style=plastic&link=https%3A%2F%2Ffr3d.dev)](https://blog.fr3d.dev)
![Static Badge](https://img.shields.io/badge/talos-v1.11.5-orange?style=plastic&logo=Talos&logoColor=%23FF7300) ![Static Badge](https://img.shields.io/badge/k8s-v1.34.0-blue?style=plastic&logo=Kubernetes&logoColor=%23326CE5&logoSize=auto) ![Static Badge](https://img.shields.io/badge/flux-v2.6.4-blue?style=plastic&logo=flux&logoSize=auto&link=https%3A%2F%2Fblog.fr3d.dev) ![Static Badge](https://img.shields.io/badge/terraform-v1.13.3-purple?style=plastic&logo=terraform&color=%237B42BC) ![Static Badge](https://img.shields.io/badge/proxmox-v9.1.4-orange?style=plastic&logo=proxmox&logoSize=auto&link=https%3A%2F%2Fblog.fr3d.dev)

**_A living, breathing home lab that champions a love of learning and discovery_**

</div>

<div align="center">

## Applications

| Application                                                                                      | Status   | Environment | URL                |
| ------------------------------------------------------------------------------------------------ | -------- | ----------- | ------------------ |
| ![Wallabag](https://img.shields.io/badge/Wallabag-5a524c?logo=wallabag&logoColor=white)          | Active   | Prod        | Read-later service |
| ![Homepage](https://img.shields.io/badge/Homepage-a9b665?logo=homepage&logoColor=white)          | Inactive | Dev, Prod   | Application Portal |
| ![IT-Tools](https://img.shields.io/badge/IT--Tools-00D8FF?logo=visualstudiocode&logoColor=white) | Inactive | Dev, Prod   | Useful tools       |

</div>

<div align="center">

## Architecture

![Terraform](https://img.shields.io/badge/Terraform-7B42BC?logo=terraform&logoColor=white)
![Proxmox](https://img.shields.io/badge/Proxmox-E57000?logo=proxmox&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-5468FF?logo=flux&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?logo=kubernetes&logoColor=white)
![Cilium](https://img.shields.io/badge/Cilium-F8C517?logo=cilium&logoColor=black)
![CoreDNS](https://img.shields.io/badge/CoreDNS-1F7DD1?logo=coredns&logoColor=white)
![ExternalDNS](https://img.shields.io/badge/External_DNS-326CE5?logo=kubernetes&logoColor=white)
![Ubiquiti](https://img.shields.io/badge/Ubiquiti-0559C9?logo=ubiquiti&logoColor=white)
![Storage](https://img.shields.io/badge/Local_Path-326CE5?logo=kubernetes&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-003545?logo=mariadb&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?logo=postgresql&logoColor=white)
![Prometheus](https://img.shields.io/badge/Prometheus-E6522C?logo=prometheus&logoColor=white)
![Grafana](https://img.shields.io/badge/Grafana-F46800?logo=grafana&logoColor=white)
![Cert-Manager](https://img.shields.io/badge/cert--manager-326CE5?logo=kubernetes&logoColor=white)
![External Secrets](https://img.shields.io/badge/External_Secrets-326CE5?logo=kubernetes&logoColor=white)
![1Password](https://img.shields.io/badge/1Password-0094F5?logo=1password&logoColor=white)
![Renovate](https://img.shields.io/badge/Renovate-1A1F6C?logo=renovatebot&logoColor=white)
![Kyverno](https://img.shields.io/badge/Kyverno-3BCEAC?logo=kubernetes&logoColor=white)
![Tailscale](https://img.shields.io/badge/Tailscale-242424?logo=tailscale&logoColor=white)
![Cloudflare](https://img.shields.io/badge/Cloudflare-F38020?logo=cloudflare&logoColor=white)

</div>

## Cluster access tooling — `kubeop.sh`

The kubeconfig for every cluster in this lab lives in 1Password (written there
by `terraform/dev/talos-pve-v3.1.0/config-export.tf` as a Secure Note titled
`<cluster-name>-kubeconfig`). It never lands on disk.

To make this ergonomic, a small zsh helper at [`_hack/scripts/kubeop.sh`](./_hack/scripts/kubeop.sh)
(also kept in `~/.zsh/kubeop.sh` on the operator workstation) fetches the
kubeconfig on demand via `op read` and feeds it to kubeconfig-aware tools via
process substitution — the config materializes as a `/dev/fd/N` pipe inside a
short-lived bash subshell and is never written to a file.

Source it from your `~/.zshrc`:

```bash
source ~/.zsh/kubeop.sh
```

It exposes four functions:

| Function | Purpose |
| --- | --- |
| `kube [env] <args>`         | kubectl (env defaults to `dev`) |
| `k9s-op [env] <args>`       | k9s |
| `k8sop <env> <tool> <args>` | any kubeconfig-aware tool: flux, helm, kustomize, kubectl-cnpg, stern, kubecolor, etc. |
| `kube-flush`                | drop the in-memory kubeconfig cache and force a re-fetch |

Examples:

```bash
kube dev get pods -A
kube dev -n freshrss rollout restart deploy/freshrss
k8sop dev flux reconcile kustomization security --with-source
k8sop dev helm list -A
k8sop dev kustomize build _lib/applications/wallabag/overlays/dev
k8sop dev stern -n wallabag .
```

**Why use this pattern in your own lab:**

- **Zero plaintext kubeconfigs at rest.** Compromise of a workstation user
  account doesn't immediately leak cluster admin creds; the secret is only
  ever in environment-variable / file-descriptor form during a single command.
- **Single source of truth.** Cluster bootstrap (Terraform) writes the
  credential; everyone who needs it pulls it the same way. No `scp`-ing
  configs, no stale `~/.kube/config` merges.
- **Multi-cluster from one shell.** `dev`, `staging`, `prod` are positional
  args — no `kubectx` dance, no risk of acting on the wrong cluster because
  you forgot to switch context.
- **Works with anything that takes `--kubeconfig`.** kubectl, k9s, flux, helm,
  kustomize, stern, kubectl-cnpg, kubecolor — all transparent.

Prerequisites: 1Password CLI (`op`) signed in, `bash` available at `/bin/bash`,
and the cluster's kubeconfig stored in the configured vault as a Secure Note
named `<cluster-name>-kubeconfig`. Override the vault per-shell with
`export OP_VAULT="..."` before sourcing the script.

Caveat: the wrapper hardcodes `--kubeconfig`, so it won't work for tools that
use a different flag (notably `talosctl`, which uses `--talosconfig`). Run
those directly.
