# ChACDN migration findings

Snapshot: 2026-09-10, cluster `omni-talos-default-opencode`.

Scope: the ChACDN workplace stack only (`kubernetes/apps/services/chacdn`,
`kubernetes/apps/network/ingressroutes/chacdn.yaml`,
`kubernetes/apps/network/ingressroutes/control.yaml`).

## What works

- `chacdn-webui` Deployment is `3/3` Running (`webui`, `workplace-api`, `kubectl-proxy`).
- Workplace API responds: `/api/health` -> `{"ok":true}`, `/api/catalog` serves the
  catalog. nginx proxies `/api/` to `127.0.0.1:3001`, so the SPA's `API = "/api"`
  calls reach the API sidecar.
- IngressRoute root route is loaded: `apps.tuntelder.com/` -> 401 from
  `oauth2-proxy-auth` (expected when unauthenticated).
- One workspace Deployment (`ws-ubuntu-desktop-u7d289613`) is Running on the
  container runtime.

## Findings

### 1. IngressRoute `/api` route points at a service port that does not exist

`kubernetes/apps/network/ingressroutes/chacdn.yaml:20` routes `PathPrefix(/api)`
to `port: api`, but the `chacdn-webui` Service exposes only `http` (80) and
`workplace` (3001) (`kubernetes/apps/services/chacdn/base/webui.yaml:133-139`).
`api` is the container port name of the `kubectl-proxy` sidecar (8001), not a
Service port.

Evidence - Traefik logs on every reconcile:

```
ingress "chacdn-webui" namespace "network" error "service port not found: api"
```

Impact: low today, because nginx already proxies `/api/` to the workplace API on
3001, so the broken Traefik router is shadowed by the port-80 route. It is dead
config that spams Traefik errors. Do not point this route at the `kubectl-proxy`
port - that would expose the raw Kubernetes API.

Fix: delete the `/api` route (nginx handles it), or point it at `port: workplace`.

### 2. `chacdn-idle-culler` is broken twice

File: `kubernetes/apps/services/chacdn/base/idle-culler.yaml`.

a) Flux `postBuild` substitution consumes the shell `${...}` variables. The
   deployed CronJob body contains literal empty substitutions:

   ```
   echo "Culling workspaces older than m (skipping persistent)"
   echo "Skipping  (lifecycle=persistent, owner: )"
   kubectl delete pvc "chacdn-home--" -n services --ignore-not-found
   ```

   `chacdn-home--` is missing `${entryId}-${owner}`, so disposable PVCs are never
   deleted. Only the deployment/service/ingress deletion paths (which use `$name`
   without braces) survive.

   Fix: escape shell vars as `$${...}` (Flux renders `$${` as a literal `${`), or
   move the script into a ConfigMap and keep substitution off it.

b) The label selector `app.kubernetes.io/component=session` matches nothing today.
   The existing `ws-ubuntu-desktop-u7d289613` Deployment only has
   `app=ws-ubuntu-desktop-u7d289613` and `chacdn-owner=u7d289613`; it predates the
   workplace API. The API does set `app.kubernetes.io/component=session`,
   `chacdn-owner`, `chacdn-entry`, and `chacdn-lifecycle` on new workspaces
   (`kubernetes/apps/services/chacdn/api/server.mjs:82-94`), so newly created
   workspaces will be culled, but pre-existing ones will not.

c) The CronJob was hitting `BackoffLimitExceeded` (job `chacdn-idle-culler-29817320`).
   Jobs are pruned after `ttlSecondsAfterFinished: 300`, so the failure log is no
   longer available; re-run and capture it before changing the script.

### 3. ~~Debug logging in the workplace API~~ FIXED

The debug `console.log` lines added while diagnosing the create hang were
reverted. `server.mjs` is clean and the regenerated ConfigMap matches.

### 4. Workspace create hangs: `kubeFetch` forwarded raw incoming headers

FIXED. `kubeFetch` (in `api/server.mjs`) spread the full incoming `req.headers`
into the fetch to the `kubectl-proxy` (localhost:8001). This passed the
browser request's stale `content-length` (e.g. `30` for `{"catalogId":...}`)
along to a POST/PATCH whose actual body was much larger (the workspace
manifest), so the proxied fetch hung forever. Result: creating any workspace
from the UI/API never returned and nothing was provisioned.

Fix: `kubeFetch` now forwards only the `x-auth-request-*` identity headers, not
raw transport headers. Verified end-to-end: container workspace creates to
`running` and VM workspace creates (VM + Service + IngressRoute + DataVolume).

## Not a ChACDN problem (context)

- `velero-ui` is crashlooping (1546 restarts) because Velero's BSL is
  `Unavailable`; `backups.${SECRET_DOMAIN_0}` will stay 503 until Velero is fixed.
- Velero BSL failure and the corrupt `aiometadata-redis` / `stremthru` data are
  tracked separately.

## Suggested fixes (repo-only)

1. `chacdn.yaml`: remove the `/api` route or set `port: workplace`.
2. `idle-culler.yaml`: escape shell `${...}` as `$${...}`; consider dropping the
   stale `component=session`-only assumption or backfilling labels.
3. ~~Revert the `server.mjs` debug logging.~~ DONE.
4. ~~Workspace create hang.~~ DONE (`kubeFetch` header leak, finding 4).
