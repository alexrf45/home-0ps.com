# Authentik recovery runbook

**Scope:** What to do when Authentik (the lab's IdP) is degraded, the
local admin can't log in, the R2 backup token expires, or the CNPG
cluster needs to be restored from object storage. Lives alongside
`_docs/sso-authentik-decision.md` (architecture) and
`_docs/authentik-sso-implementation-handoff.md` (implementation
state).

**Audience:** Lab operator (you). Assumes `op` is signed in,
`kubeop.sh` is sourced, and you have shell access to the cluster.

---

## 1. Local-admin recovery (IdP degraded)

The `akadmin` local admin account is **never federated**. It exists
solely so you can log in when the OIDC/SAML side of Authentik is
broken (database wedge, misconfigured flow, deleted brand, etc.).

### Where the credentials live

1Password item `authentik_${ENVIRONMENT}` (e.g. `authentik_dev`) in
the HomeLab vault. Relevant fields:

| Field | Use |
| --- | --- |
| `bootstrap_email` | The recovery email tied to `akadmin`. |
| `bootstrap_password` | Initial password for `akadmin`. **Rotate after first login.** |
| `bootstrap_token` | API admin token. Long-lived; use for `curl`/terraform-managed app configs when the UI is unreachable. |

These values are synced into the K8s Secret `authentik-env` by the
`authentik-env` `ExternalSecret` in `_lib/applications/authentik/base/external-secret.yaml`,
which the chart consumes via `authentik.existingSecret.secretName`.

### Login path

1. Go directly to `https://dev.int.auth.home-0ps.com/if/flow/default-authentication-flow/`
   (skip any custom brand redirect that may be misconfigured).
2. Username: `akadmin`. Password: the `bootstrap_password` value from
   1P.
3. Admin UI is at `/if/admin/`.

If the default auth flow itself is broken, use the API with the
bootstrap token instead:

```sh
op run --no-masking -- bash -c '
  curl -s -H "Authorization: Bearer $AUTHENTIK_BOOTSTRAP_TOKEN" \
    https://dev.int.auth.home-0ps.com/api/v3/core/users/me/ | jq .
'
```

A 200 with the `akadmin` user record means the API + DB are healthy;
the problem is in the UI / flow layer.

### Rotating `bootstrap_password`

After any login event you suspect was observed (shared screen,
recorded session), rotate:

1. Log in as `akadmin`, change the password in `/if/admin/users/`.
2. Update the `bootstrap_password` field in the `authentik_${ENVIRONMENT}`
   1P item to match.
3. The `authentik-env` ExternalSecret will resync on its next
   `refreshInterval` (5m). The new value only matters for **future**
   reinstalls — running pods don't re-read it. So no pod bounce
   needed; the rotation is purely about keeping 1P and the live
   account in sync.

### Post-recovery checklist

After regaining access, walk through these in the Admin UI:

- **Brands** (`/if/admin/core/brands/`) — confirm the default brand
  hostname matches `dev.int.auth.home-0ps.com` and the flow
  bindings (auth, invalidation, recovery) point at flows that
  actually exist.
- **Outposts** (`/if/admin/outpost/outposts/`) — if the embedded
  outpost is unhealthy, restart its Deployment.
- **Providers & Applications** (`/if/admin/core/applications/`) —
  any provider stuck in "warning" state usually means a downstream
  app's client secret rotated without Authentik knowing. Re-paste
  from 1P.
- **Federated sources** (`/if/admin/core/sources/`) — if a source
  caused the outage (bad SAML metadata, expired OIDC discovery doc),
  disable it before re-enabling MFA enforcement so you can log in
  again as a federated user.

---

## 2. R2 backup token rotation

The per-bucket R2 token has a 180-day TTL (lab cadence; check
`token_expires_on` in `terraform/dev/authentik-object-storage/` outputs).

Full procedure: see `terraform/modules/object-storage/README.md` under
"Token rotation flow (R2)". Summary:

```sh
cd terraform/dev/authentik-object-storage
op run --no-masking -- terraform apply \
  -target=module.authentik_backup.cloudflare_api_token.r2_bucket[0] \
  -target=module.authentik_backup.onepassword_item.r2_creds[0]
```

This re-issues the token and overwrites the `authentik-r2-creds` 1P
item. ESO's `authentik-r2-creds` `ExternalSecret` (15m refresh)
syncs the new pair into K8s.

To make the rotation take effect immediately for in-flight WAL
archive ops, bounce the CNPG primary's instance manager:

```sh
kube dev -n authentik delete pod authentik-${ENVIRONMENT}-cluster-1
```

(CNPG will fail over to a replica and the new pod picks up the
fresh secret.)

---

## 3. CNPG cluster recovery from R2

**Dev cluster has no recovery `ObjectStore`** — the `ob-recovery`
overlay was deferred to prod (see
`_docs/authentik-sso-implementation-handoff.md` for context). If you
need to restore dev right now, you'll have to create the recovery
ObjectStore on the spot.

### Wiring in a recovery ObjectStore (prod or emergency dev)

1. Copy the structure of `_lib/applications/authentik/overlays/dev/ob-archiver.enc.yaml`
   (decrypt locally with SOPS first) into `ob-recovery.plain.yaml`.
2. Change:
   - `metadata.name` → `authentik-${ENVIRONMENT}-cluster-backup` (or
     whatever you'll reference from `bootstrap.recovery`).
   - `destinationPath` → the S3-style path of the backup you want to
     restore from (typically the same bucket as the archiver, since
     R2 holds the lab's only copy).
3. SOPS-encrypt to `ob-recovery.enc.yaml` with the same regex used
   for the archiver: `--encrypted-regex '^(data|destinationPath|endpointURL)$'`.
4. Add `ob-recovery.enc.yaml` to the overlay `kustomization.yaml`
   resources list.

### Switching the Cluster spec to bootstrap.recovery

CNPG bootstrap is **one-shot and immutable** (see
`project_cnpg_bootstrap_immutable` in lab memory). To re-bootstrap
from R2:

1. Suspend the `authentik` Flux Kustomization so Flux doesn't fight
   you:
   ```sh
   k8sop dev flux suspend kustomization authentik
   ```
2. Delete the existing CNPG `Cluster` and its instance PVCs:
   ```sh
   kube dev -n authentik delete cluster authentik-${ENVIRONMENT}-cluster
   kube dev -n authentik delete pvc -l cnpg.io/cluster=authentik-${ENVIRONMENT}-cluster
   ```
3. Edit `_lib/applications/authentik/overlays/dev/database.yaml`:
   replace the `bootstrap.initdb` block with a `bootstrap.recovery`
   block referencing your recovery ObjectStore (pattern: see
   archived `_docs/archive/wallabag/overlays/dev/database.yaml`,
   which used `recoveryTarget.backupID` to pin a specific backup).
4. Add an `externalClusters` entry pointing to the recovery
   ObjectStore (same archived file shows the shape).
5. Resume Flux:
   ```sh
   k8sop dev flux resume kustomization authentik
   ```
6. Watch the new cluster bootstrap:
   ```sh
   k8sop dev kubectl-cnpg status authentik-${ENVIRONMENT}-cluster -n authentik
   ```

After recovery, **revert `database.yaml` back to `bootstrap.initdb`** in
a follow-up commit. Leaving `bootstrap.recovery` in place is harmless
(CNPG ignores it once the cluster is bootstrapped) but confuses
future readers.

---

## 4. Common failure modes (quick reference)

| Symptom | First check | Likely fix |
| --- | --- | --- |
| Server pods CrashLoop with `secret not found` | `kube dev -n authentik get externalsecret` | 1P item `authentik_${ENVIRONMENT}` missing fields, or ESO not synced — `kube dev -n authentik describe externalsecret authentik-env` |
| Login flow returns 500 | Server pod logs (`kube dev -n authentik logs -l app.kubernetes.io/component=server --tail=200`) | Usually a custom flow with a missing stage — log in as `akadmin` via the default flow URL and inspect bindings |
| Backups not landing in R2 | CNPG primary pod logs for the Barman sidecar | Token expired (check `EXPIRES_ON` in 1P item `authentik-r2-creds`) — rotate per §2 |
| `dev.int.auth.home-0ps.com` returns NXDOMAIN | ExternalDNS logs | Confirm HTTPRoute exists and the SAN is on the wildcard cert (`kube dev -n networking get cert wildcard-tls -o yaml`) |
| TLS handshake fails on `dev.int.auth.home-0ps.com` | `kube dev -n networking describe cert wildcard-tls` | SAN missing — the wildcard `*.home-0ps.com` does NOT cover three-label hosts; verify `dev.int.auth.home-0ps.com` is in `dnsNames` |
