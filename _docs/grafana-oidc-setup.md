# Grafana OIDC via Authentik — setup runbook

**Scope:** What you (the operator) need to do in the Authentik admin UI
and 1Password before Grafana's OIDC login starts working. The code side
(ExternalSecret + helmrelease `auth.generic_oauth` block + cert SAN) is
already shipped via Phase 2 of the SSO rollout.

**Audience:** Lab operator. Assumes Authentik dev is up and you've
logged in once as `akadmin` (see `_docs/authentik-recovery-runbook.md`
§1 if not).

---

## What the code already does

| File | Purpose |
| --- | --- |
| `_lib/observability/kube-prometheus-stack/external-secret-oidc.yaml` | ESO syncs 1P item `grafana_oidc_${ENVIRONMENT}` → K8s Secret `grafana-oidc` with keys `client_id`, `client_secret`. |
| `_lib/observability/kube-prometheus-stack/helmrelease.yaml` (`grafana:` block) | Adds `envValueFrom` for `GF_AUTH_GENERIC_OAUTH_CLIENT_ID/SECRET` + `grafana.ini` `auth.generic_oauth` block with Authentik URLs, scopes, and group → role JMESPath. |
| `_lib/networking/gateway/tls.yaml` | Adds `dev.int.grafana.home-0ps.com` to wildcard cert SANs (three-label deep, not covered by `*.home-0ps.com`). |

Until the 1P item exists, ESO can't produce the K8s Secret, so the new
Grafana pod will sit pending in a rollout (the old pod keeps serving).
No downtime — by design.

---

## What you need to do

### 1. (Optional but recommended) Create the role-mapping groups

Authentik admin → **Directory → Groups → Create**:

| Group name | Purpose |
| --- | --- |
| `Grafana Admins` | Maps to Grafana org `Admin` role (full edit/permissions in the default org) |
| `Grafana Editors` | Maps to Grafana org `Editor` role (create/edit dashboards) |

Skip the groups entirely if you want every OIDC user to get `Viewer`
(the JMESPath fallback). Add yourself to `Grafana Admins` if you want
admin access via OIDC.

### 2. Create the OAuth2/OpenID Provider

Authentik admin → **Applications → Providers → Create → OAuth2/OpenID
Provider**:

| Field | Value |
| --- | --- |
| Name | `Grafana (dev)` |
| Authentication flow | `default-source-authentication` (or whatever your default is) |
| Authorization flow | `default-provider-authorization-implicit-consent` |
| Client type | `Confidential` |
| Client ID | leave as auto-generated — **record this value** |
| Client Secret | leave as auto-generated — **record this value** |
| Redirect URIs/Origins (RegEx) | `https://dev.int.grafana.home-0ps.com/login/generic_oauth` (literal — escape dots if you switch to a regex) |
| Signing Key | the default `authentik Self-signed Certificate` is fine for dev |
| Scopes | leave the three default `authentik default OAuth Mapping: OpenID '<scope>'` entries (`openid`, `email`, `profile`) checked |
| **Property mappings → Scopes** | Also add `authentik default OAuth Mapping: OpenID 'groups'` — this is what emits the `groups` claim that the JMESPath in `grafana.ini` reads. Without it, every user lands on the `Viewer` fallback. |

Save.

### 3. Create the Application

Authentik admin → **Applications → Applications → Create**:

| Field | Value |
| --- | --- |
| Name | `Grafana` |
| Slug | `grafana` |
| Provider | select the `Grafana (dev)` provider from step 2 |
| Launch URL | `https://dev.int.grafana.home-0ps.com/` |

Save. (Optionally restrict access via **Policy/Group/User Bindings**
— add the `Grafana Admins` and `Grafana Editors` groups to allow only
mapped users in.)

### 4. Put the credentials in 1Password

Create a new 1P item in the HomeLab vault:

| Field | Value |
| --- | --- |
| Item title | `grafana_oidc_dev` (note: matches `grafana_oidc_${ENVIRONMENT}`) |
| `client_id` | the Client ID recorded in step 2 |
| `client_secret` | the Client Secret recorded in step 2 |

ESO refreshes the `grafana-oidc` `ExternalSecret` every 5m, so within
5 minutes the K8s Secret materializes. To skip the wait:

```sh
kube dev -n monitoring annotate externalsecret grafana-oidc \
  force-sync="$(date +%s)" --overwrite
```

### 5. Restart Grafana to pick up the new env vars

The deployment is mid-rollout (new pod stuck on missing secret); once
the Secret exists, the new pod starts cleanly and the old one
terminates. Speed it up:

```sh
kube dev -n monitoring rollout restart deployment/monitoring-kube-prometheus-stack-grafana
kube dev -n monitoring rollout status deployment/monitoring-kube-prometheus-stack-grafana --timeout=120s
```

### 6. Verify

1. Browse to `https://dev.int.grafana.home-0ps.com/`.
2. You should see a **"Sign in with Authentik"** button under the
   regular login form. (Local admin still works — break-glass.)
3. Click it → redirects to Authentik → consent → redirects back to
   Grafana logged in as the OIDC user.
4. In Grafana: top-left → your user icon → **Profile** → confirm the
   user shows the role from your Authentik group membership (Admin /
   Editor / Viewer).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| New Grafana pod stays `0/1` after rollout | `grafana-oidc` Secret doesn't exist yet | `kube dev -n monitoring get externalsecret grafana-oidc` — should be `SecretSynced`. If not, check 1P item exists and `force-sync` annotation triggered a refresh. |
| Redirect to Authentik fails with `redirect_uri_mismatch` | Provider redirect URI doesn't match | In Authentik provider, set Redirect URIs to exactly `https://dev.int.grafana.home-0ps.com/login/generic_oauth`. |
| Logged in but every user is `Viewer` | `groups` claim not being emitted | Add the `groups` property mapping to the provider's Scopes list (step 2). Verify via `https://dev.int.auth.home-0ps.com/application/o/<slug>/userinfo/` returning a `groups` array. |
| Browser shows TLS warning on grafana | Cert SAN not yet issued | `kube dev -n networking get cert wildcard-tls` — wait for `Ready: True` after the cert reissues with the new SAN. |
| `Failed to fetch OAuth token` in Grafana logs | Wrong `token_url` or client secret mismatch | Verify `kube dev -n monitoring get secret grafana-oidc -o jsonpath='{.data.client_secret}' \| base64 -d` matches what Authentik shows. Rotate via Authentik UI if needed. |

---

## Out of scope (future)

- Per-app OIDC for other lab services (cryptpad, freshrss, future
  Thoth) — same provider/application pattern.
- Mapping Grafana **server admin** (the global super-admin) via OIDC
  — currently `allow_assign_grafana_admin: false`; promote via
  `grafana-cli` if needed.
- Auto-login (skip the Grafana login form, go straight to Authentik).
  Currently `auto_login: false` to preserve break-glass UX.
