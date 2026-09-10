# ChACDN findings log

Snapshot: 2026-09-10, cluster `omni-talos-default-opencode`.
Scope: `kubernetes/apps/services/chacdn`, `kubernetes/apps/kubevirt`,
`kubernetes/apps/network/ingressroutes` (chacdn + control).

## What works (verified 2026-09-10)

- `chacdn-webui` 3/3 Running; workplace API serves /api/health, /api/me,
  /api/catalog, /api/workspaces (list/create/delete/restart).
- Workspace creation: instant for containers (Deployment + Service +
  IngressRoute) and VMs (Secret-cloudinit + VirtualMachine + DataVolume +
  Service + IngressRoute).
- Fresh VM self-configures: apt retry install of xfce4 + deps, Selkies
  portable runtime, both systemd units up, cloud-init `done`; the workplace
  API pod reaches Selkies through the kubevirt Service (`HTTP/1.1 200`)
  with basic auth `user`/`mypasswd` behind oauth2-proxy.

## Resolved

1. `kubeFetch` forwarded the full request headers to the kubectl-proxy — the
   browser's stale `content-length` header made the proxied POST hang forever.
   Fixed to forward only `x-auth-request-*`.

2. VM cloud-init: the `virtualmachine-validator` webhook rejects inline
   `cloudInitNoCloud.userData` > 2048 bytes, so every VM create was silently
   denied. User-data moved to a Secret (`cloudInitNoCloud.secretRef` — field
   name is `secretRef`, not `userDataSecretRef`), created by the API flow; add
   `secrets get/create/delete` to `chacdn-vm-control` Role.

3. Selkies: pip package ships `selkies-gstreamer` (not `selkies`), and jammy's
   gstreamer 1.20 lacks the `GstWebRTC-1.0` GIR binding → Namespace errors.
   Cloud-init now installs the official portable runtime tarball (v1.6.2,
   bundled gstreamer >= 1.22). Correct CLI: `selkies-gstreamer-run` with
   underscore-style flags (`--enable_https`, not `--enable-https`).

4. Heredocs inside cloud-init runcmd break (marker "not found"); unit files
   are written with cloud-init `write_files` instead. cloud-init `packages:`
   does not retry and one transient mirror hiccup (Hash Sum mismatch from
   local HTTP cache) killed whole first boots — installs are in runcmd with
   retries now.

5. kubevirt ns PodSecurity drift: `operator/base/operator.yaml` Namespace
   dropped the pod-security label because the app-root `namespace.yaml`
   overwrote the namespace without it. Both declare `enforce/audit/warn:
   privileged` now; deleting the virt-handler DS lets the operator recreate
   it once labels are right.

6. `chacdn.yaml` dead `/api` route (`port: api` never existed) removed.

7. idle-culler: shell `${...}` was eaten by Flux envsubst → literal empty
   substitutions. Escaped as `$${...}` so Flux renders shell literals.

## Open

- idle-culler ignores VM workspaces (VirtualMachines in kubevirt ns).
- Pre-API workspace `ws-ubuntu-desktop-u7d289613` lacks culler labels; it is
  40h+ old and never flagged. Recycle it manually or backfill labels.
- Not ChACDN: `velero-ui` crashlooping (BSL Unavailable) — `backups.` host
  stays 503; corrupt `aiometadata-redis` / `stremthru` data tracked separately.
