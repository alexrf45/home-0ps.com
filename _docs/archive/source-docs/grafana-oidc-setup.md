# Grafana OIDC via Authentik — setup runbook

**Scope:** What you (the operator) need to do in the Authentik admin UI
and 1Password to wire Grafana's OIDC login to Authentik. The code side
(ExternalSecret + helmrelease `auth.generic_oauth` block + cert SAN) is
shipped via Phase 2 of the SSO rollout.

**Audience:** Lab operator. Assumes Authentik dev is up and you've
logged in once as `akadmin` (see `_docs/authentik-recovery-runbook.md`
§1 if not).

**Pattern:** Follows the canonical Authentik Grafana integration —
[integrations.goauthentik.io/monitoring/grafana/](https://integrations.goauthentik.io/monitoring/grafana/).
Roles are mapped via **per-app entitlements**, not global groups. This
is the recommended pattern in Authentik 2026.x; older docs (and earlier
revisions of this runbook) recommended groups, which still works but
is less granular.

---

## What the code already does

| File | Purpose |
| --- | --- |
| `_lib/observability/kube-prometheus-stack/external-secret-oidc.yaml` | ESO syncs 1P item `grafana_oidc_${ENVIRONMENT}` → K8s Secret `grafana-oidc` with keys `client_id`, `client_secret`. |
| `_lib/observability/kube-prometheus-stack/helmrelease.yaml` (`grafana:` block) | Adds `envValueFrom` for `GF_AUTH_GENERIC_OAUTH_CLIENT_ID/SECRET` + `grafana.ini` `auth.generic_oauth` block with Authentik URLs, scopes (`openid email profile entitlements offline_access`), and entitlement → role JMESPath. |
| `_lib/networking/gateway/tls.yaml` | Adds `dev.int.grafana.home-0ps.com` to wildcard cert SANs. |

---

## What you need to do in the Authentik UI

Log in at `https://dev.int.auth.home-0ps.com/if/admin/`.

### 1. Create the OAuth2 / OpenID provider

**Applications → Providers → Create → OAuth2/OpenID Provider**.

| Field | Value |
| --- | --- |
| Name | `Grafana (dev)` |
| Authentication flow | leave the default (`default-source-authentication`) |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | `Confidential` |
| Client ID | leave as auto-generated — **record this** |
| Client Secret | leave as auto-generated — **record this** |
| Redirect URIs (mode: `Strict`) | `https://dev.int.grafana.home-0ps.com/login/generic_oauth` |
| Logout URI | `https://dev.int.grafana.home-0ps.com/logout` |
| Logout method | `Front-channel` |
| Signing Key | default `authentik Self-signed Certificate` is fine for dev |

Expand **Advanced protocol settings → Selected Scopes** and ensure
these are checked (the first three are usually selected by default
when you create a new OAuth2 provider; you'll need to explicitly add
`entitlements` and `offline_access`):

- ✅ `authentik default OAuth Mapping: OpenID 'openid'`
- ✅ `authentik default OAuth Mapping: OpenID 'email'`
- ✅ `authentik default OAuth Mapping: OpenID 'profile'`
- ✅ `authentik default OAuth Mapping: OpenID 'entitlements'` *(this is the one that emits the `entitlements` claim Grafana reads for role mapping — must be explicitly added)*
- ✅ `authentik default OAuth Mapping: OpenID 'offline_access'` *(needed because the helmrelease sets `use_refresh_token: true`)*

> **Why not groups?** In current Authentik the `profile` scope already
> includes group membership, so a separate "groups" property mapping
> isn't shipped. Entitlements are per-application instead of per-user
> globally — the canonical Authentik recommendation for new OIDC
> integrations.

Save.

### 2. Create the Application

**Applications → Applications → Create**.

| Field | Value |
| --- | --- |
| Name | `Grafana` |
| Slug | `grafana` |
| Provider | select the `Grafana (dev)` provider from step 1 |
| Launch URL | `https://dev.int.grafana.home-0ps.com/` |

Save.

### 3. Create the three role-mapping entitlements on the Application

This is the entitlements-equivalent of creating groups; it lives on
the Application, not in the global Directory.

**Applications → Applications → click `Grafana` → Application
entitlements tab → Create**. Do this **three times**, once per role:

| Entitlement name | Maps to Grafana role |
| --- | --- |
| `Grafana Admins` | `Admin` |
| `Grafana Editors` | `Editor` |
| `Grafana Viewers` | `Viewer` (the JMESPath fallback also lands here, so explicit binding is optional) |

> **Why these exact names?** The JMESPath in `grafana.ini`
> (`role_attribute_path`) literally tests for these strings:
> `contains(entitlements, 'Grafana Admins') && 'Admin' || ...`. Mismatch
> by even a space and the user falls through to Viewer.

For each entitlement, after creating it, scroll down to **Bindings**
on that entitlement and bind the user(s) or group(s) who should get
that role. **At minimum, bind yourself to `Grafana Admins`** so you can
test admin access.

> **You can keep your global Groups too** if you created any from the
> earlier (incorrect) revision of this runbook — they don't conflict
> with entitlements. They just won't be read by Grafana anymore
> because the JMESPath now looks at `entitlements`, not `groups`.

### 4. Put the credentials in 1Password

Create a 1P item in the HomeLab vault:

| Field | Value |
| --- | --- |
| Item title | `grafana_oidc_dev` (matches `grafana_oidc_${ENVIRONMENT}`) |
| `client_id` | the Client ID recorded in step 1 |
| `client_secret` | the Client Secret recorded in step 1 |

### 5. Force the ESO sync and Grafana rollout

ESO refreshes every 5m on its own; skip the wait with:

```sh
kube dev -n monitoring annotate externalsecret grafana-oidc \
  force-sync="$(date +%s)" --overwrite
```

If the helmrelease was updated *after* you populated 1P, the pod is
probably already running with the new config. If not, restart:

```sh
kube dev -n monitoring rollout restart deployment/monitoring-kube-prometheus-stack-grafana
kube dev -n monitoring rollout status deployment/monitoring-kube-prometheus-stack-grafana --timeout=180s
```

> **Known papercut:** the Grafana PVC is RWO. When the rolling-update
> places the new pod on a different node than the old, the new pod
> hangs with `Multi-Attach error` because the old pod still holds the
> volume. Break the deadlock manually: `kube dev -n monitoring delete
> pod <old-grafana-pod>`. Tracked as a follow-up to set
> `grafana.deploymentStrategy.type: Recreate` on the chart.

### 6. Verify

1. Browse to `https://dev.int.grafana.home-0ps.com/`.
2. You should see a **"Sign in with Authentik"** button under the
   regular login form. (Local admin still works — break-glass.)
3. Click it → redirects to Authentik → consent → redirects back to
   Grafana logged in as your OIDC user.
4. Top-left → your user icon → **Profile** → confirm the role matches
   your entitlement binding (Admin if you bound yourself to
   `Grafana Admins`).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| New Grafana pod stays `0/3 Init` | `grafana-oidc` Secret doesn't exist | `kube dev -n monitoring get externalsecret grafana-oidc` — should be `SecretSynced`. If not, check 1P item and `force-sync` annotation. |
| New Grafana pod stays `0/3` with `Multi-Attach error` | RWO PVC held by old pod on a different node | Delete the old pod by name (see §5 note). |
| Redirect to Authentik fails with `redirect_uri_mismatch` | Provider Redirect URI doesn't match | In Authentik provider, set Redirect URIs (mode `Strict`) to exactly `https://dev.int.grafana.home-0ps.com/login/generic_oauth`. |
| Logged in but every user is `Viewer` | `entitlements` scope mapping not in provider's Selected Scopes, **or** entitlement name doesn't match the JMESPath string exactly, **or** user not bound to the entitlement | (a) Check the provider's Advanced protocol settings includes the `entitlements` mapping. (b) Compare entitlement names char-for-char against the role_attribute_path. (c) Check Application entitlements → entitlement → Bindings tab. |
| `entitlements` claim absent from userinfo response | Provider's Selected Scopes missing the entitlements mapping | Re-add it. Verify with `curl -H "Authorization: Bearer $TOKEN" https://dev.int.auth.home-0ps.com/application/o/userinfo/` after logging in. |
| Browser shows TLS warning on grafana | Cert hasn't reissued with the new SAN | `kube dev -n networking get cert wildcard-tls` — wait for `Ready: True`. Verify SAN list with `kube dev -n networking get secret wildcard-tls -o jsonpath='{.data.tls\.crt}' \| base64 -d \| openssl x509 -noout -ext subjectAltName`. |
| `Failed to fetch OAuth token` in Grafana logs | Wrong `token_url` or client secret mismatch | Verify `kube dev -n monitoring get secret grafana-oidc -o jsonpath='{.data.client_secret}' \| base64 -d` matches what Authentik shows. Rotate via the Authentik provider edit page if needed. |

---

## Out of scope (future)

- Per-app OIDC for other lab services (cryptpad, freshrss, future
  Thoth) — same provider/application/entitlement pattern.
- Mapping Grafana **server admin** (the global super-admin) via OIDC
  — currently `allow_assign_grafana_admin: false`; promote via
  `grafana-cli` if needed.
- Auto-login (skip the Grafana login form, go straight to Authentik).
  Currently `auto_login: false` to preserve break-glass UX.
- Switching the Grafana Deployment to `Recreate` strategy so the RWO
  PVC + multi-node multi-attach papercut stops biting on every upgrade.
