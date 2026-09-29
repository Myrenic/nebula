# Authentication

`oauth2-proxy` in the `auth` namespace is the only identity gate in the cluster.
It authenticates over OIDC against Keycloak, and Traefik's forwardAuth middleware
delegates the check to it.

## Sign-in flow

- Traefik terminates TLS with the cert-manager certificate `domain-0-prod`
  (Cloudflare DNS-01) at the MetalLB L2 address `10.0.50.4`. Nothing sits in
  front of it: clients reach `10.0.50.4` directly.
- A protected `IngressRoute` carries the middleware chain `oauth2-proxy-auth`
  (`kubernetes/apps/network/exposure/middlewares.yaml`), which is
  `oauth2-proxy-errors` + `oauth2-proxy-forwardauth`. The forwardAuth calls
  `http://oauth2-proxy.auth.svc.cluster.local/oauth2/auth` and copies
  `X-Auth-Request-User`, `X-Auth-Request-Email`, `X-Auth-Request-Groups`,
  `X-Auth-Request-Preferred-Username` and `X-Auth-Request-Access-Token` upstream.
- A `401` from the forwardAuth is caught by the errors middleware, which serves
  `/oauth2/sign_in`. The custom sign-in page
  (`oauth2-proxy/base/templates-configmap.yaml`) redirects the browser to
  `https://auth.${SECRET_DOMAIN_0}/oauth2/start`.
- oauth2-proxy redirects to Keycloak at `https://keycloak.${SECRET_DOMAIN_0}`
  (realm `nebula`) and handles the callback on
  `https://auth.${SECRET_DOMAIN_0}/oauth2/callback`. The session cookie is scoped
  to `.${SECRET_DOMAIN_0}`.
- The OIDC settings live in `oauth2-proxy/base/helmrelease.yaml`:
  `provider: oidc`,
  `oidc-issuer-url: https://keycloak.${SECRET_DOMAIN_0}/realms/nebula`,
  `oidc-groups-claim: groups`, `redirect-url`, `cookie-domain`,
  `set-xauthrequest: true` (the last one makes oauth2-proxy emit the
  `X-Auth-Request-*` headers for the upstream service).

## Two realms, two jobs

Keycloak keeps its built-in `master` realm for administration and one realm,
`nebula`, for the applications. They are separate on purpose: nobody who signs in to
an app is an administrator, and the account you administer with never has to appear
in the realm the applications authenticate against.

| Realm | Who is in it | What it is for |
| --- | --- | --- |
| `master` | the bootstrap admin (`KEYCLOAK_ADMIN_USERNAME`) and any administrator you add there deliberately | the admin console, `https://keycloak.${SECRET_DOMAIN_0}/admin/master/console/` |
| `nebula` | the people who sign in to this cluster's apps, and no `realm-management` role for any of them | OIDC for oauth2-proxy and Forgejo; self-service at `https://keycloak.${SECRET_DOMAIN_0}/realms/nebula/account` |

## The realm is not in git

Nothing in this repository manages Keycloak's configuration, so the realm, its
clients and its users exist only in Keycloak's database. What is hand-made:

| Object | Where its value comes from |
| --- | --- |
| The realm `nebula` | settings only - `sslRequired: external`, the default token lifetimes, no self-registration - so a rebuild is one API call |
| The client `webui` (confidential) | the secret is `client-secret` in the `keycloak-webui-oauth` Secret |
| The client `forgejo` (confidential) | the secret is `FORGEJO_OAUTH_CLIENT_SECRET` in `cluster-secrets`, so git holds it, encrypted |
| The users | created in the console; a realm created this way starts empty |

That call, with the two client secrets filled in from the sources above:

```bash
TOKEN=$(curl -sS -d "client_id=admin-cli&username=$KEYCLOAK_ADMIN_USERNAME&password=$KEYCLOAK_ADMIN_PASSWORD&grant_type=password" \
  "https://keycloak.${SECRET_DOMAIN_0}/realms/master/protocol/openid-connect/token" | jq -r .access_token)

curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://keycloak.${SECRET_DOMAIN_0}/admin/realms" -d @- <<EOF
{
  "realm": "nebula",
  "displayName": "Nebula",
  "sslRequired": "external",
  "clients": [
    {
      "clientId": "webui",
      "secret": "<client-secret from the keycloak-webui-oauth Secret>",
      "redirectUris": ["https://auth.${SECRET_DOMAIN_0}/oauth2/callback"],
      "webOrigins": ["https://auth.${SECRET_DOMAIN_0}"]
    },
    {
      "clientId": "forgejo",
      "secret": "${FORGEJO_OAUTH_CLIENT_SECRET}",
      "redirectUris": ["https://code.${SECRET_DOMAIN_0}/user/oauth2/Keycloak/callback"],
      "webOrigins": ["https://code.${SECRET_DOMAIN_0}"]
    }
  ]
}
EOF
```

A client that is given a secret is confidential (`publicClient: false`), with the
authorization-code flow on and direct access grants off - which is what both
applications need, since each authenticates with its own secret and never handles a
user's password. The `redirectUris` have to match `redirect-url` in
`oauth2-proxy/base/helmrelease.yaml` and the callback in
`forgejo/base/helmrelease.yaml` character for character: a mismatch is answered on
the login page with `Invalid parameter: redirect_uri`, not with a log line.

To remove a realm, `Realm settings` -> `Delete realm` in the console, or:

```bash
curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://keycloak.${SECRET_DOMAIN_0}/admin/realms/<realm>"
```

`master` cannot be deleted, which is the point of keeping administration there: it
is the way back in.

## Moving to another realm is a cutover, not a rename

The realm name is part of `oidc-issuer-url` and `autoDiscoverUrl`, so it is a change
to two manifests plus an empty realm to move into. In this order:

1. Create the new realm with the same clients and the same secrets (above). Both
   realms answer; nothing has changed yet.
2. Point those two manifests at the new realm and push. Flux rolls oauth2-proxy,
   which reads the issuer at start.
3. Sign in to prove it, then delete the old realm.

Between 2 and 3 a browser with a live session cookie keeps working while a new
sign-in fails against the old issuer, so do not leave that gap overnight. Sessions
do not cross realms: everyone signs in once more.

## Add a user

1. In realm `nebula` (`https://keycloak.${SECRET_DOMAIN_0}`, then the realm
   selector), create the user and set a password. That is the whole recipe:
   oauth2-proxy's `email-domain` is `*`, so any account in the realm passes the
   gate and every route behind `oauth2-proxy-auth` is reachable. The token's
   `groups` claim is still forwarded as `X-Auth-Request-Groups`, but no route in
   this cluster authorizes on it - which is why a new realm here needs no groups.
2. Give that user no roles. Administration happens in `master`, with the bootstrap
   admin; a role in `nebula` would only widen what a signed-in app user can reach
   and nothing here needs it.

## Out-of-band secrets

The oauth2-proxy client credentials are not in git. They live in the Secret
`keycloak-webui-oauth` in the `auth` namespace, referenced by
`config.existingSecret` in `oauth2-proxy/base/helmrelease.yaml` and created by
hand:

```bash
kubectl -n auth create secret generic keycloak-webui-oauth \
  --from-literal=client-id=webui \
  --from-literal=client-secret=<keycloak-client-secret> \
  --from-literal=cookie-secret=<OAUTH2_PROXY_COOKIE_SECRET from cluster-secrets>
```

`client-secret` exists only on the `webui` client in Keycloak; `cookie-secret` is
copied from `OAUTH2_PROXY_COOKIE_SECRET` in
`kubernetes/apps/common/cluster-secrets.sops.yaml`. The Secret object itself is
in no kustomization and no SOPS file, so a rebuilt cluster needs it recreated by
hand. oauth2-proxy reads these values at start: restart the Deployment after
replacing the Secret.

The realm is `nebula` and the client is `webui` (confidential,
redirect URI `https://auth.${SECRET_DOMAIN_0}/oauth2/callback`). Keycloak's
bootstrap admin and Postgres credentials come from `KEYCLOAK_ADMIN_USERNAME`,
`KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_DB_PASSWORD` in `cluster-secrets`; that
admin is the `master` realm's, and administers everything.
