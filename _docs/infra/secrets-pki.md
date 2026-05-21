# Infra guide: Secrets & PKI

**Layers:** `external-secrets-operator` + `secrets` (runtime secrets); `pki` (internal CA / trust).
**Two trust roots:** 1Password (secret material) and an internal CA (service-to-service TLS).
**Principle:** keep secrets **rotatable** — never hardcode a 1P-backed field, even a non-sensitive one (rotation flexibility is the goal).

---

## Secret flow

```
1Password  →  1Password Connect  →  External Secrets Operator  →  Kubernetes Secret  →  workload
   (vault)      (in-cluster API)        (ExternalSecret CR)          (synced)
```

| Component | Path | Notes |
| --- | --- | --- |
| 1Password Connect | `_lib/secrets/onepassword/` | chart `connect@2.0.5`, `onepassword` ns; `op-connect-tls` cert; `servicemonitor.yaml` scraped by Prometheus |
| External Secrets Operator | `_lib/controllers/external-secrets/` | chart `0.20.1`; its Flux layer `dependsOn` controllers **+ pki** (mTLS) |
| ClusterSecretStore | `_lib/secrets/cluster-secret-store/cluster-secret-store.yaml` | the cluster-wide store apps reference |

Apps declare an `ExternalSecret` referencing a 1Password item; ESO produces the K8s Secret. Convention: one 1P item → one `ExternalSecret` → one Secret, even when it emits multiple key shapes (see the Authentik DB+chart secret in [apps/authentik.md](../apps/authentik.md#secrets)).

## SOPS (Flux-decrypted secrets)

For secrets that live in git (ObjectStore creds, Cloudflare DNS token, Tailscale keys), Flux decrypts with the `sops-age` secret in `flux-system`. Config at `_clusters/dev/.sops.yaml`:

- files matching `*values.yaml` are **fully** encrypted;
- other YAML encrypts only `data`/`stringData` (or per-file `encrypted-regex`, e.g. ObjectStore `^(data|destinationPath|endpointURL)$`).

> **Project rule:** never modify or re-encrypt `.env`/SOPS files without explicit confirmation — the operator manages secrets. Claude writes plaintext drafts (`*.plain.yaml`); the operator encrypts.

The Age key is seeded from 1Password at bootstrap (Terraform `kubernetes_secret.sops_age`).

## Internal PKI

`_lib/pki/` provides service-to-service TLS independent of Let's Encrypt:

| Path | What |
| --- | --- |
| `certauth/homelab-internal-ca-keypair.yaml` | internal CA keypair (SOPS) |
| `certauth/int-cluster-issuer.yaml` | cert-manager Issuer backed by the CA |
| `trust-manager/` | trust-manager `v0.16.0` |
| `trust-bundle/bundle.yaml` | distributes the CA bundle to namespaces |

Live internal certs: `trust-manager-tls`, `op-connect-tls`, `barman-cloud-{client,server}-tls` (CNPG↔Barman mTLS). The `pki` layer is a dependency of ESO so 1P Connect's mTLS is available before secrets sync.

## CNPG network-policy dependency (easy to miss)

Every new `<app>-cnpg-allow` CCNP must allow ingress from the CNPG operator (database ns + `cloudnative-pg` label) on **8000** — otherwise fresh clusters get stuck at `1/N` instances. See `_lib/security/cilium-network-policies/*-cnpg-allow.yaml`.

## Rotation notes

- **1P-backed fields** resync on the `ExternalSecret` `refreshInterval` (typically 5–15m). Running pods don't re-read — rotation matters for the *next* reinstall/restart (e.g. Authentik `bootstrap_password`). Force a sync with `kube dev -n <ns> annotate externalsecret <name> force-sync="$(date +%s)" --overwrite`.
- **R2/Cloudflare tokens** are Terraform-managed (90–180d TTL); re-issue via targeted `terraform apply` and ESO picks up the rewritten 1P item ([apps/authentik.md](../apps/authentik.md#recovery-and-day-2)).
