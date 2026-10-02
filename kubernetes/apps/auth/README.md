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
| `nebula` | the people who sign in to this cluster's apps, and no `realm-management` role for any of them | OIDC for oauth2-proxy; self-service at `https://keycloak.${SECRET_DOMAIN_0}/realms/nebula/account` |

## The realm is in git, create-only

The realm `nebula`, its confidential client `webui` and the client's secret
placeholder are declared in `keycloak/base/realm/nebula.json` and applied by the
`keycloak-realm-import` Job, which reads the file from the `keycloak-realm`
ConfigMap. No secret is in the file: the client's `secret` field carries
`$(env:OAUTH2_CLIENT_SECRET)`, and the Job takes that variable from the
hand-made `keycloak-webui-oauth` Secret - the same Secret oauth2-proxy reads, so
the realm and the proxy cannot drift apart.

The Job is create-only by construction: it asks the admin API for the realm and
exits without importing if it already exists. On a fresh cluster that is what
creates the realm, the client and the gate; on this cluster, where the realm is
already hand-made, it writes nothing. The consequence is worth stating plainly:
editing `nebula.json` does **not** change a realm that already exists.
`keycloak-config-cli` has no `import.behavior=IGNORE_EXISTING` option - it is not
in 6.5.1 (nor in v3, v4 or v5) - so the guard in the Job is what implements those
semantics. The Job's header says how to switch to the reconciling behaviour and
what to read first (`import.managed.client=full` deletes clients a live realm
holds and the JSON does not).

What is still hand-made:

| Object | Where its value comes from |
| --- | --- |
| The users | created in the console; a realm created this way starts empty, and a password belongs in no git file |
| The client secret itself | `client-secret` in the `keycloak-webui-oauth` Secret, created out of band (below) |

If the Job cannot run - the `keycloak-webui-oauth` Secret does not exist yet, so
its pod cannot start - the same realm can be created by hand. That call, with the
client secret filled in from the source above, is the manual equivalent:

```bash
TOKEN=$(curl -sS -d "client_id=admin-cli&username=$KEYCLOAK_ADMIN_USERNAME&password=$KEYCLOAK_ADMIN_PASSWORD&grant_type=password" \
  "https://keycloak.${SECRET_DOMAIN_0}/realms/master/protocol/openid-connect/token" | jq -r .access_token)

curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  "https://keycloak.${SECRET_DOMAIN_0}/admin/realms" -d @- <<EOF
{
  "realm": "nebula",
  "displayName": "Nebula",
  "loginTheme": "nebula",
  "sslRequired": "external",
  "clients": [
    {
      "clientId": "webui",
      "secret": "<client-secret from the keycloak-webui-oauth Secret>",
      "redirectUris": ["https://auth.${SECRET_DOMAIN_0}/oauth2/callback"],
      "webOrigins": ["https://auth.${SECRET_DOMAIN_0}"]
    }
  ]
}
EOF
```

A client that is given a secret is confidential (`publicClient: false`), with the
authorization-code flow on and direct access grants off - which is what the
application needs, since it authenticates with its own secret and never handles a
user's password. The `redirectUri` has to match `redirect-url` in
`oauth2-proxy/base/helmrelease.yaml` character for character: a mismatch is
answered on the login page with `Invalid parameter: redirect_uri`, not with a log
line.

To remove a realm, `Realm settings` -> `Delete realm` in the console, or:

```bash
curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" \
  "https://keycloak.${SECRET_DOMAIN_0}/admin/realms/<realm>"
```

`master` cannot be deleted, which is the point of keeping administration there: it
is the way back in.

## The sign-in theme

The pages a person signs in on are themed from git.
`kubernetes/apps/auth/keycloak/base/theme/nebula/` holds a `theme.properties` and
one stylesheet; `base/kustomization.yaml` turns that directory into the
`keycloak-theme` ConfigMap, and the HelmRelease mounts its files one at a time onto
the paths Keycloak reads a theme from - `/opt/keycloak/themes/nebula/login/...` -
because a ConfigMap is flat and a theme is a directory tree.

Nothing about a page's markup is copied. The theme declares `parent=keycloak.v2`
and so inherits every template from the theme Keycloak ships, then paints over
PatternFly 5 in CSS. The look is Apple's - one system-blue accent, system
typography, translucent materials used quietly, short eased transitions, no
JavaScript - and `theme/nebula/login/resources/css/nebula.css` opens with what
that means rule by rule and why a Keycloak theme implements it in CSS rather than
in the React the design was written for. The one non-obvious dependency is
`styles=css/styles.css css/nebula.css` in `theme.properties`: a child theme's
`styles` replaces the parent's list rather than adding to it, so the parent's own
layout sheet is named again to keep it.

The theme is selected by a single word inside the realm, and a realm that has
never been told otherwise uses the bundled one. `loginTheme: nebula` is part of
`realm/nebula.json`, so the import sets it when the realm is created; for a realm
that already exists - which the create-only Job deliberately leaves alone - it is
one call:

```bash
# $TOKEN as above.
curl -sS -H "Authorization: Bearer $TOKEN" \
  "https://keycloak.${SECRET_DOMAIN_0}/admin/realms/nebula" |
  jq '.loginTheme = "nebula"' |
  curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "https://keycloak.${SECRET_DOMAIN_0}/admin/realms/nebula" -d @-
```

The realm is read back and one field changed rather than sending the field alone:
a `PUT` to a realm replaces the whole representation, so a partial body would
silently reset the clients and the token lifetimes.

Editing the theme is then one step on top of the push, because two caches hold it:
the kubelet does not refresh `subPath` mounts under a running pod, and a server
started in production caches theme files in memory.

```bash
kubectl -n auth rollout restart deploy/keycloak
```

A third cache is the browser's, and it is the one that makes a theme change look
like it did not happen. Theme resources are served with `Cache-Control`, and the
URL they are served from - `/resources/<key>/login/nebula/css/nebula.css` - does
not change when the stylesheet does; measured against 26.7.4, the `<key>` survives
both an edit to `theme.properties` and a restart of the server. At Keycloak's
default of 30 days, anyone who has loaded the sign-in page once would keep the old
stylesheet for a month. `KC_SPI_THEME_STATIC_MAX_AGE: "600"` in the HelmRelease
pulls that down to ten minutes, which is short enough that a change appears on the
next visit and long enough that the PatternFly bundle is still cached the rest of
the time. A hard reload shows it immediately either way.

That is the whole loop - a stylesheet change, a push, and that restart. Light and
dark are not two themes: the colour set is chosen by the class Keycloak's own
script puts on `<html>` from `prefers-color-scheme`.

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
replacing the Secret. The `keycloak-realm-import` Job reads `client-secret` from
this same Secret, so on a rebuild it must exist before that Job's pod can start -
create it before the first reconcile, as this section does by hand.

The realm is `nebula` and the client is `webui` (confidential,
redirect URI `https://auth.${SECRET_DOMAIN_0}/oauth2/callback`, declared in
`keycloak/base/realm/nebula.json`). Keycloak's
bootstrap admin and Postgres credentials come from `KEYCLOAK_ADMIN_USERNAME`,
`KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_DB_PASSWORD` in `cluster-secrets`; that
admin is the `master` realm's, and administers everything, including the realm
import Job above.
