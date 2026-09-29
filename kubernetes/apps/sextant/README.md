# Sextant

[Sextant](https://codeberg.org/DAWO/DAWO-Sextant) is the fleet control plane for
NixOS devices: a device's configuration is data in a git repository, a change is
proved to build by a nix evaluation before it can be committed, and devices pull
their own updates in rings. It is the upstream project behind the `DAWO` core the
mytops workspace images borrow their module layout from, and it is the piece
`bouwstraat` deliberately left out ("a control plane...[is] a much larger
decision").

Nothing here provisions a device: it is the console and its database. A device
becomes a device by checking in with the check-in token and following the overlay
repository with `comin` - the console never connects to a device.

## What is deployed

| Object | What it is |
| --- | --- |
| `HelmRelease/sextant` | The console, the gate-runner and the Postgres cluster the chart brings with it, from `deploy/helm` in the project's git repository, pinned to the release tag `v0.91.0`. |
| `GitRepository/sextant` | That chart. The project publishes images, not charts, so the chart is read out of the release tag - chart and images move together because the image tag falls back to the chart's `appVersion`. |
| `Deployment/sextant` | The console. It edits the overlay clone on a Longhorn volume, commits through the gate, and serves the UI. |
| `Deployment/sextant-gate` | The validation gate: a nix-capable runner that evaluates the candidate overlay before the console is allowed to commit. Writes are fail-closed - no reachable gate, no commit. |
| `Cluster/sextant-pg` | The observed plane (check-ins, tokens, preferences, the LUKS recovery-key escrow), created by the same chart. |
| `HelmRelease/cloudnative-pg` | The operator that Cluster needs, in its own namespace. |

## Exposure

`https://sextant.${SECRET_DOMAIN_0}` through Traefik, with the wildcard
certificate. The route is marked **public** in the exposure directory, not behind
`oauth2-proxy-auth`, and that is deliberate: the console *is* an OIDC client of the
same Keycloak realm, and its authorization model is derived from the `groups`
claim Keycloak returns. oauth2-proxy in front would authenticate twice and still
leave the console needing its own login to know who owns what. The console has no
password login of its own, so "public" here means "Keycloak is the gate".

## Identity

One confidential Keycloak client in realm `mytops`, no password login of its own:

| | |
| --- | --- |
| Client | `sextant` (confidential, standard flow, PKCE S256) |
| Redirect URI | `https://sextant.${SECRET_DOMAIN_0}/callback` |
| Client scope | `groups` - a Group Membership mapper with `full.path=true` and the ID token enabled, because the console compares the claim to its role groups exactly |
| Role groups | `/sextant-owners` is the only one configured: it can change the fleet and write to the overlay. `/sextant-editors` and `/sextant-viewers` are added to the HelmRelease when there is somebody to put in them. |

Neither the client nor the group is managed by anything in this repository: this
cluster's Keycloak is hand-configured (that is stated in the root README's
bootstrap notes), and its admin API is the only way to make them. Reproducing
them from scratch:

```bash
KC=https://keycloak.${SECRET_DOMAIN_0}/admin/realms/mytops
TOKEN=$(curl -s -d client_id=admin-cli -d username="$KEYCLOAK_ADMIN_USERNAME" \
  -d password="$KEYCLOAK_ADMIN_PASSWORD" -d grant_type=password \
  "https://keycloak.${SECRET_DOMAIN_0}/realms/master/protocol/openid-connect/token" | jq -r .access_token)

# The claim the console reads. Full paths, so the role groups below start with /.
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "$KC/client-scopes" -d '{
  "name":"groups","protocol":"openid-connect",
  "attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"},
  "protocolMappers":[{"name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
    "config":{"claim.name":"groups","full.path":"true","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}]}'

curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "$KC/clients" -d '{
  "clientId":"sextant","name":"Sextant fleet console","enabled":true,"protocol":"openid-connect",
  "publicClient":false,"standardFlowEnabled":true,"directAccessGrantsEnabled":false,
  "rootUrl":"https://sextant.'"${SECRET_DOMAIN_0}"'","baseUrl":"https://sextant.'"${SECRET_DOMAIN_0}"'",
  "redirectUris":["https://sextant.'"${SECRET_DOMAIN_0}"'/callback"],
  "webOrigins":["https://sextant.'"${SECRET_DOMAIN_0}"'"],
  "attributes":{"pkce.code.challenge.method":"S256"}}'

# The client scope has to be attached through its own endpoint; the client
# representation's defaultClientScopes field is not writable.
CID=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/clients?clientId=sextant" | jq -r '.[0].id')
SID=$(curl -s -H "Authorization: Bearer $TOKEN" "$KC/client-scopes" | jq -r '.[]|select(.name=="groups")|.id')
curl -s -X PUT -H "Authorization: Bearer $TOKEN" "$KC/clients/$CID/default-client-scopes/$SID"

curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X POST "$KC/groups" -d '{"name":"sextant-owners"}'
```

The client secret belongs to the console and lives in `cluster-secrets` as
`SEXTANT_OIDC_CLIENT_SECRET`; rotate it in Keycloak's admin console and write the
new value there.

## Secrets

One Secret (`sextant`) is substituted from `cluster-secrets` at build time; no
secret is a Helm value and none is stored in this repository in the clear. Every
key the console and the gate-runner read:

| Key in `cluster-secrets` | What it is |
| --- | --- |
| `SEXTANT_CHECKIN_TOKEN` | What devices present when they check in. |
| `SEXTANT_SECRET_KEY` | Base64 of 32 bytes; seals typed secrets at rest, including the escrowed LUKS recovery keys. |
| `SEXTANT_SESSION_KEY` | Base64 of 32 bytes; seals session cookies. Required as soon as an issuer is set - the console refuses to start without it rather than fall back to something weaker. |
| `SEXTANT_OIDC_CLIENT_SECRET` | The Keycloak client's secret. |
| `SEXTANT_API_TOKEN` | Bearer token for the machine API. |
| `SEXTANT_GATE_TOKEN` | Shared between console and gate-runner; the chart maps it to `SEXTANT_GATE_TOKEN` for the console while the runner reads `GATE_TOKEN`, both from this one Secret. |
| `SEXTANT_OVERLAY_NETRC` | One line of netrc: the credentials the console clones and pushes the overlay with, and the gate-runner clones it with. |

Rotating `SEXTANT_SECRET_KEY` is not a plain swap: put the new key first and keep
the old one, comma-separated, until nothing is sealed under it any more. A key
removed while a value still needs it makes that value unreadable - and the values
in question are the recovery keys for encrypted devices.

## The overlay repository

`https://code.tuntelder.com/myrenic/sextant-overlay` (private). It holds
`fleet.json`, the flake that turns that document into one NixOS host per device,
the core (the reference core for now - see its README) and the option catalog the
console renders. The console commits to it; the devices follow it.

The access token the console pushes with is the netrc above. To rotate it:
create a token on the forge with `write:repository`, and replace
`SEXTANT_OVERLAY_NETRC` with `machine code.${SECRET_DOMAIN_0} login <user>
password <token>`.

Pointing the console at a different overlay is one value in the HelmRelease
(`gitRemote.url`).

## Operational notes

- **The gate is fail-closed.** `gateMode: remote` means no reachable gate-runner
  means no writes, by design. Check
  `kubectl -n sextant exec deploy/sextant-gate -- wget -qO- localhost:8090/healthz`
  first if the console refuses to save anything.
- **No database backup yet.** The chart's own backup writes to an S3-compatible
  object store and this cluster's off-site copy is Velero to Azure Blob, so
  `cnpg.backup` is off and the namespace is captured by the Velero schedules
  instead. That capture is a file-level copy of a running database, which is not
  the same thing as a database backup, and what it protects - the LUKS recovery
  keys - is material nothing else can rebuild. Pointing the chart at an object
  store is the first thing to do before this fleet holds real devices.
- **First boot is slow.** The gate-runner fetches nixpkgs before its startup
  probe passes (five minutes of budget), so the first reconcile of this
  Kustomization can legitimately take a few minutes.
- **Images** come from BB Open's public registry
  (`forgejo.bb-open.com/bb-open/sextant*`) and are pulled anonymously; the
  project ships x86_64 only, so this runs on the amd64 nodes it has.
- **Upgrading** means moving `ref.tag` in `base/source.yaml`: the chart and both
  images are versioned together in the release tag.
