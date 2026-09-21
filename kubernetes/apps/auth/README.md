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
  (realm `mytops`) and handles the callback on
  `https://auth.${SECRET_DOMAIN_0}/oauth2/callback`. The session cookie is scoped
  to `.${SECRET_DOMAIN_0}`.
- The OIDC settings live in `oauth2-proxy/base/helmrelease.yaml`:
  `provider: oidc`,
  `oidc-issuer-url: https://keycloak.${SECRET_DOMAIN_0}/realms/mytops`,
  `oidc-groups-claim: groups`, `redirect-url`, `cookie-domain`,
  `set-xauthrequest: true` (the last one makes oauth2-proxy emit the
  `X-Auth-Request-*` headers for the upstream service).
- Workspace streams are gated twice. The per-workspace `IngressRoute`s in the
  mytops repository add `mytops-workspace-owner` after `oauth2-proxy-auth`. That
  middleware asks the workplace API (`/api/stream-auth`) whether the signed-in
  user owns the host in the request, because a workspace host is derived from its
  owner's email (`ws-<entry>-u<hash>`).

## Add a user

1. Create the user in the Keycloak admin console
   (`https://keycloak.${SECRET_DOMAIN_0}`, realm `mytops`) and set a password.
2. Put the user in the Keycloak groups that match the `groups` array of the
   catalog entry in the mytops app repository (`webui/public/catalog.json`). The
   names must match exactly; an entry without `groups` is visible to everyone
   signed in.
3. The SPA filters its catalog by the groups the workplace API returns for
   `/api/me`, which the API fills from oauth2-proxy's `X-Auth-Request-Groups`
   header (fed by the token's `groups` claim). Group changes appear at the next
   sign-in.

Workspaces are named `ws-<entry>-<slug>`, where the slug is a hash of the user's
email, and the SPA destroys the running ones on sign-out.

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

The Keycloak realm is `mytops` and the client is `webui` (confidential,
redirect URI `https://auth.${SECRET_DOMAIN_0}/oauth2/callback`). Keycloak's
bootstrap admin and Postgres credentials come from `KEYCLOAK_ADMIN_USERNAME`,
`KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_DB_PASSWORD` in `cluster-secrets`.
