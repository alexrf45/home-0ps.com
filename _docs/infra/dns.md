# Infra guide: DNS

**Layer:** `dns` (Flux Kustomization, depends on `secrets`).
**Internal zone:** `home-0ps.com`, served by UniFi (`10.3.3.1`). Records published by ExternalDNS.
**Two DNS surfaces:** ExternalDNS (record publishing) + CoreDNS (in-cluster resolution).

---

## ExternalDNS (record publishing)

`_lib/dns/external-dns/` — chart `1.19.0`, **UniFi webhook provider** targeting the UniFi gateway at `10.3.3.1`. It watches HTTPRoutes/Services and publishes `*.home-0ps.com` records into UniFi's DNS so LAN clients resolve `dev.int.<app>.home-0ps.com`. Cloudflare credentials are **not** used here — those are independent and only feed cert-manager DNS-01 (see below).

## CoreDNS split-horizon (in-cluster resolution)

**Problem it solves:** in-cluster back-channels (e.g. Grafana → Authentik OIDC token exchange) need to resolve `dev.int.auth.home-0ps.com`, but cluster CoreDNS doesn't know the internal zone — it NXDOMAIN'd. This was the final blocker for Grafana OIDC ([ADR-0001](../decisions/0001-sso-authentik.md)).

**Fix:** a split-horizon forward so the internal zone resolves via UniFi:

```
home-0ps.com:53 { forward . 10.3.3.1 }
```

- **Live:** applied as a manual edit to the CoreDNS ConfigMap.
- **IaC:** committed as a Talos inlineManifest in `terraform/dev/talos-pve-v3.1.0/talos.tf` (commit `8b3af1f`) — **apply status unverified**. A cluster rebuild *without* applying this reverts the manual edit. Close the drift with `/terraform-plan` → `/terraform-apply` (interactive 1Password auth).

## cert-manager DNS-01 (Cloudflare)

The Let's Encrypt ClusterIssuers solve DNS-01 challenges via a **Cloudflare API token** (`Zone:DNS:Edit` + `Zone:Zone:Read`), stored in `_lib/networking/clusterissuers/cf-secrets.yaml` (SOPS). This is **separate** from the R2 storage token ([ADR-0002](../decisions/0002-object-storage-r2.md)) — keep edge/DNS perms and storage perms apart. See [infra/networking.md](networking.md#tls-and-clusterissuers).

## Gotchas

- **The `*.home-0ps.com` wildcard does not cover three-label hosts.** `dev.int.auth` is *three* labels deep — both DNS and the wildcard TLS cert must handle it explicitly (the cert via explicit SANs).
- NXDOMAIN on a `dev.int.*` host: check ExternalDNS logs *and* that the CoreDNS split-horizon forward is present in the live ConfigMap.
