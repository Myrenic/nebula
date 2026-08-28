# Authentication Setup — OAuth2 Proxy + Azure Entra ID

OAuth2 Proxy sits in front of services (Flux, Longhorn) and authenticates users via
Azure Entra ID (OIDC). Traefik's ForwardAuth middleware delegates auth checks to OAuth2 Proxy.

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
