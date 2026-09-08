# Authentication Setup — OAuth2 Proxy + Keycloak

OAuth2 Proxy sits in front of services (Flux, Longhorn, ChACDN webui) and
authenticates users via **Keycloak** (OIDC). Traefik's ForwardAuth middleware
delegates auth checks to OAuth2 Proxy.

## Keycloak (current IdP)

- Realm: `chacdn` (Keycloak admin console at `https://keycloak.<domain>`)
- Client: `webui` (confidential, redirect URI `https://auth.<domain>/oauth2/callback`)
- Admin + DB credentials: `${KEYCLOAK_ADMIN_*}` / `${KEYCLOAK_DB_PASSWORD}` in `cluster-secrets`

### Out-of-band client secret

The oauth2-proxy client credentials are NOT in SOPS. They live in the manually
created `keycloak-webui-oauth` Secret (auth namespace), created once like the
`arc-github-auth` secret:

```bash
kubectl -n auth create secret generic keycloak-webui-oauth \
  --from-literal=client-id=webui \
  --from-literal=client-secret=<keycloak-client-secret> \
  --from-literal=cookie-secret=<OAUTH2_PROXY_COOKIE_SECRET from cluster-secrets>
```

### Adding users / assigning apps

1. Create users in the Keycloak admin console (realm `chacdn`).
2. Create/assign **groups** in Keycloak matching the `groups` array of the
   entry in `chacdn/webui/public/catalog.json` (entry without `groups` =
   visible to everyone logged in). The group names in Keycloak and the catalog
   must match; the SPA reads them from the token's `groups` claim via
   oauth2-proxy (`X-Auth-Request-Groups`).
3. Rebuild the webui (`npm run build` in `chacdn/webui`), commit, Flux applies.

Each user gets their own workspace pods (`ws-<entry>-<user-slug>`), which are
deleted on sign-out / session expiry.

## Legacy: Azure Entra ID

The previous Azure Entra ID provider config was replaced by Keycloak. The
`AZURE_*` vars may still exist in `cluster-secrets` but are no longer used.
The `AUTHENTIK_*` vars are unused leftovers.

## Required SOPS Variables

Edit with: `sops kubernetes/apps/common/cluster-secrets.sops.yaml`

### Azure Entra ID

| Variable | Description | Where to find |
|---|---|---|
| `AZURE_CLIENT_ID` | Application (client) ID | Azure Portal → App Registrations → Overview |
| `AZURE_CLIENT_SECRET` | Client secret value | Azure Portal → App Registrations → Certificates & secrets |
| `AZURE_TENANT_ID` | Directory (tenant) ID | Azure Portal → Azure Active Directory → Overview |

### OAuth2 Proxy

| Variable | Description | How to generate |
|---|---|---|
| `OAUTH2_PROXY_COOKIE_SECRET` | Cookie encryption key | `openssl rand -base64 32 \| tr -- '+/' '-_'` |

### Variables to Remove (Authentik)

These are no longer needed and can be cleaned up:

- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_TOKEN`
- `AUTHENTIK_OIDC_CLIENT_ID`
- `AUTHENTIK_OIDC_CLIENT_SECRET`
- `AUTHENTIK_POSTGRESQL_PASSWORD`

## Azure App Registration Setup

1. Go to **Azure Portal** → **Azure Active Directory** → **App Registrations**
2. Open your existing app registration (or create a new one)
3. Update the **Redirect URI** to: `https://auth.<your-domain>/oauth2/callback`
4. Under **API permissions**, ensure `openid`, `email`, and `profile` scopes are granted

## Architecture

```
Internet → Cloudflare Tunnel → Traefik (10.0.69.100:443)
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              flux.domain    longhorn.domain   auth.domain
                    │               │               │
                    └───────┬───────┘               │
                            │                  OAuth2 Proxy
                    ForwardAuth middleware     (sign-in + callback)
                            │                       │
                            └───────────────────────┘
                                        │
                                  Azure Entra ID
                                  (OIDC Provider)
```

Protected routes use Traefik's ForwardAuth middleware which checks authentication
with OAuth2 Proxy. Unauthenticated users are redirected to Azure Entra ID for sign-in.
