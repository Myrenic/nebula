# Nebula Unified Workplace Plan — Kasm + abcdesktop.io + linuxserver.io (sealskin) on KubeVirt

> Goal: one browser app suite that hosts **containers (today)**, **Linux VMs and Windows VMs via KubeVirt** in Kubernetes, with a unified catalog, auth, streaming, storage and lifecycle — without rebuilding Kasm from scratch.

## 1. Current State (scan 2026-09-09)

**What exists — `chacdn` is the workplace:**
- SPA: `kubernetes/apps/services/chacdn/webui` (Vite+React, `src/lib/k8s.ts`, `App.tsx`, `Dashboard.tsx`, `SessionView.tsx`) built to `base/www/` → `base/chacdn-webui.configmap.json` via `webui/scripts/build-configmap.mjs`.
- Runtime: `base/webui.yaml` — `nginx:1.27-alpine` + `alpine/k8s:1.36.0 kubectl proxy` sidecar, `SA chacdn-control`.
- RBAC: `base/control.yaml` (`services` Deployments/Services) + `apps/network/ingressroutes/control.yaml` (`network` IngressRoutes). Control plane is the browser talking directly to K8s API via the proxy.
- Per-user instance: `ws-{entryId}-{slug}` where `slug = hash(email)` (`lib/k8s.ts:25`), `Deployment` (image `ghcr.io/linuxserver/webtop:ubuntu-kde` / `firefox`, `PUID/PGID=1000`, `KasmVNC:3000`, `1Gi /dev/shm`, `256Mi req` / `2-4Gi lim`) + `Service:3000` + `IngressRoute` `Host(ws-*.${SECRET_DOMAIN_0})` → Traefik `websecure` + `domain-0-prod-tls`.
- Catalog: static `base/www/catalog.json` (`apps: [{id, name, type: desktop|app, image, env, groups}]`), no persistence — stateless pods.
- Auth: `auth/oauth2-proxy` (OIDC to `auth/keycloak` realm `chacdn`, `cookie-domain=.${SECRET_DOMAIN_0}`, `set-xauthrequest`), Traefik middlewares `oauth2-proxy-auth` chain (`forwardAuth` + `errors` → `oauth2-proxy`). Groups gate catalog entries.
- Ingress: `network/traefik` v3.7 (2 replicas, `allowCrossNamespace=true`), `network/ingressroutes/chacdn.yaml` (`apps.${DOMAIN}` → `chacdn-webui:80/8001`), `middlewares.yaml` chain.
- Cluster: Talos single-node (Omni), Longhorn 1.11.2 `defaultClassReplicaCount:1` (cron `replica-adjuster` raises to 2 when 2nd node appears), Flux SOPS+age, Velero 2 replicas + Azure Blob, `monitoring/kube-prometheus-stack+loki`.
- Dead code: `network/ingressroutes/coder.yaml` → `dev-platform/coder` (namespace gone).

**Gaps vs vision:**
No server-side workplace API (the browser currently reaches the Kubernetes API through `kubectl proxy`), no explicit per-entry persistence/lifecycle policy, no VM capability proof, no KubeVirt/CDI, no RDP gateway, `catalog.json` hand-edited, and no observability per workspace.

## 2. What to Steal From Each Platform

| Platform | Keep (minimal) | Skip for now |
|---|---|---|
| **Kasm Workspaces 1.19** (kasm.com, GA on K8s via Helm, KasmVNC + Guacamole/FreeRDP 3.0, RDPGFX, pools/autoscale, file/clip DLP, recording, NVIDIA MiG, ZTNA) | Workspace registry + group ACL, Helm-on-k8s pattern, RDP gateway model, autoscale/pools, DLP knobs, GPU slicing concept | Separate API/Manager/DB/Redis, ZTNA/OpenZiti, full Guacamole infra — Traefik+Keycloak+Flux already cover it |
| **abcdesktop.io** (k8s-native, `pyos`+`router` (NGINX+Lua) + `oc.user`, JWT-encrypted pod IP, per-user pod, per-app ephemeral container/pods, `filer`/`sound`/`printer` sidecars, PVC/home via NFS/hostPath/PVC, OIDC/LDAP) | Per-user pod isolation, per-app ephemeral containers (RAI), PVC home, sidecar services, JWT session idea | Lua router, Mongo/Memcached, custom `pyos` — your `kubectl-proxy` + SPA is the leaner `pyos` |
| **linuxserver.io webtop / sealskin** (`ghcr.io/linuxserver/webtop:*`, `firefox`, `chromium` on KasmVNC, `PUID/PGID`, `PIXELFLUX_WAYLAND`) | Curated image catalog, env-flag pattern, breadth of DEs — cheapest way to grow `catalog.json` | Building own images — just pin `ghcr.io/linuxserver/*:tag` |

**Synthesis:** Kasm = product UX + RDP/enterprise, abcdesktop = k8s-native isolation model, linuxserver = image supply chain. Nebula already is 70% of the way on the linuxserver path.

## 3. Target Architecture (lazy — extend chacdn, don't rebuild)

```
Browser → https://apps.$DOMAIN (Traefik, oauth2-proxy → Keycloak OIDC)
        → IngressRoute chacdn-webui (network)
        → workplace API (trusted identity headers + server-side catalog validation)
          ├─ runtime=container → Deployment + Service:3000 + IngressRoute → KasmVNC
          └─ runtime=vm-*      → VirtualMachine (KubeVirt) via CDI DataVolume clone
                                → virt-launcher pod → guest RDP → guacd → browser
Storage: Longhorn RWO + CDI for image import/clone; evaluate RWX only after multi-node migration testing
Network: masquerade first, Multus/VLAN later
AuthZ: Keycloak groups → server-side catalog enforcement → resources labelled `chacdn-owner={slug}`
```

One catalog, one auth, one ingress, two runtime backends, one streaming abstraction. Keep the SPA, but add a small server-side workplace API before it can provision VMs; never give raw Kubernetes manifest creation to a browser-reachable identity.

## 4. Phased Roadmap

### Phase 0 — Secure and Harden Containers (no infra risk, immediate value)
- **P0-1 Workplace API:** replace browser → `kubectl proxy` access with a small in-cluster API. It reads trusted oauth2-proxy identity headers, validates the requested catalog entry server-side, derives the owner itself, and creates only allowed resources. Do this before granting access to VM/PVC/DataVolume APIs.
- **P0-2 Persistence policy:** add `persistent: true|false` to each catalog entry. Create/mount a user PVC only for persistent desktop/dev entries; keep browser-isolation and disposable apps stateless. Do not mount one shared home into arbitrary images.
- **P0-3 Lifecycle & quotas:** make lifecycle explicit per entry (`disposable`, `suspend`, or `persistent`), then add resource caps and an idle culler appropriate to that policy. Avoid a generic culler that deletes persistent work unexpectedly.
- **P0-4 Catalog v2:** extend `CatalogEntry` with validated `runtime`, resources, persistence/lifecycle, and later VM template identifiers. Keep `postBuild` SOPS substitution.
- **P0-5 Streaming polish:** expose KasmVNC health; retain existing iframe clipboard/fullscreen permissions; use KasmVNC file transfer before adding sidecars.

### Phase 1 — KubeVirt Capability Spike (prove the platform before product work)
- **P1-1 Verify Talos/KVM prerequisites:** verify `/dev/kvm`, `/dev/vhost-net`, and `/dev/net/tun` from the real node; confirm KubeVirt's privileged `virt-handler` can run on Talos. Do not rely on an assumed Omni feature name or label.
- **P1-2 Install KubeVirt + CDI through Flux:** install the supported operator and KubeVirt/CDI CRs, then verify `KubeVirt` is `Available` and a disposable Linux VM boots from a CDI `DataVolume`.
- **P1-3 Test operational behavior:** test a VM through a node reboot/Longhorn recovery, measure CPU/RAM usage, and establish a safe VM limit. This single-node cluster cannot live migrate.
- **P1-4 Golden images after the spike:** import a disposable Ubuntu image first. Add a sysprepped Windows image only after Linux boot/storage/remote-access are proven; do not commit licensing material or images to Git.

### Phase 2 — Linux VMs (first user-facing VM win)
- **P2-1 RDP gateway proof:** deploy `guacd` + Guacamole (or another maintained browser RDP gateway) and prove browser → RDP → a fixed Linux test VM. Use KubeVirt VNC only for administrator/bootstrap access through `virtctl vnc`, not as the user-facing path.
- **P2-2 API VM path:** add a server-side VM template allowlist and create `VirtualMachine` resources from template IDs; do not send VM manifests from the SPA. Start with 1 vCPU/2Gi, `masquerade`, normal RWO Longhorn storage, and a guest with RDP enabled.
- **P2-3 Catalog integration:** add `runtime: vm-linux` only after the fixed VM and gateway work. Use one conservative VM quota based on actual node capacity, not an assumed two-VM target.

### Phase 3 — Windows VMs (highest friction, do last)
- **P3-1 Windows template:** create an EFI/Q35, virtio-driver, sysprepped, RDP-enabled Windows template. Include Windows-appropriate Hyper-V features and guest-agent choices; Windows does not fit the generic Linux VM manifest.
- **P3-2 Reuse the proven RDP gateway:** connect Windows through the Phase 2 gateway, with a strict capacity limit (`maxWindowsVMs=1` initially).
- **P3-3 AD/Keycloak sync** only if needed. Add pools only after a persistent Windows VM, restart behavior, activation, patching, and backup/restore work reliably.

### Phase 4 — UX Parity (only after P0-P3 works)
- Admin pool view (Grafana dashboards from `monitoring`), server-side audit log, session DLP (clipboard filter), CUPS/PulseAudio sidecars if demanded, and GPU only when a measured workload requires it.
- Do not use Kubernetes ephemeral containers as a normal application runtime: they are debugging-oriented and have lifecycle/security limitations. Run isolated apps as ordinary short-lived Pods/Deployments instead.
- Evaluate RWX storage and live migration only after at least two KVM-capable nodes and a real migration test. KubeVirt requires RWX PVCs for live migration; Longhorn RWX uses NFS share managers and has already been identified in this repository as a Talos reboot risk.

## 5. Prioritized Backlog (next 5 PRs)

| # | Title | Files | Effort | Impact |
|---|---|---|---|---|
| 1 | `chacdn: replace browser Kubernetes API access with workplace API` | `services/chacdn/base/*`, SPA API client | M | Required security boundary for containers, PVCs, and VMs |
| 2 | `chacdn: catalog persistence and lifecycle policies` | catalog schema, workplace API, SPA | S | Makes disposable vs persistent behavior explicit |
| 3 | `chacdn: resource caps and policy-aware idle lifecycle` | workplace API, namespace limits/policies | S | Prevents single-node exhaustion without deleting wanted state |
| 4 | `infra: KubeVirt + CDI disposable Linux capability spike` | `kubernetes/apps/kubevirt/*` | M | Validates Talos/KVM, CDI, Longhorn, and actual node capacity |
| 5 | `workplace: Guacamole RDP proof against fixed Linux VM` | `services/guacamole/*`, ingress, test VM | M | Validates the browser desktop path before catalog integration |

After #5: add server-side VM templates and Linux catalog integration, then Windows.

## 6. Implementation Notes (smallest diff)

**Catalog v2 example (`www/catalog.json`):**
```json
{
  "apps": [
    {
      "id": "ubuntu-desktop",
      "name": "Ubuntu Desktop",
      "type": "desktop",
      "runtime": "container",
      "image": "ghcr.io/linuxserver/webtop:ubuntu-kde",
      "persistence": "persistent",
      "lifecycle": "suspend",
      "groups": ["ubuntu-desktop"]
    },
    {
      "id": "ubuntu-vm",
      "name": "Ubuntu VM",
      "type": "desktop",
      "runtime": "vm-linux",
      "memory": "2Gi",
      "cpu": "2",
      "storage": "10Gi",
      "template": "ubuntu-2404-rdp",
      "persistence": "persistent"
    }
  ]
}
```

**Workplace API RBAC direction:**
```yaml
# Granted only to the in-cluster workplace API, never to the browser SPA.
- apiGroups: ["kubevirt.io"]
  resources: ["virtualmachines","virtualmachineinstances"]
  verbs: ["get","list","create","patch","delete"]
- apiGroups: ["cdi.kubevirt.io"]
  resources: ["datavolumes"]
  verbs: ["get","list","create","delete"]
```

**VM creation direction:**
```ts
// SPA sends only { catalogId }. The workplace API identifies the user,
// validates the catalog entry, and renders a vetted VM template server-side.
```

**Container persistence direction:**
```ts
// Create/mount a per-user claim only when entry.persistence === "persistent".
volumes: [
  { name: "dshm", emptyDir: { medium: "Memory", sizeLimit: "1Gi" } },
  { name: "home", persistentVolumeClaim: { claimName: `chacdn-home-${owner}` } }
],
// + volumeMount { name:"home", mountPath:"/config" }
```

## 7. Risks & Mitigations

- **Browser-to-Kubernetes trust boundary:** `kubectl proxy --disable-filter=true` is appropriate for tightly scoped experiments, not untrusted VM/PVC provisioning. Put validation and ownership enforcement in the workplace API before adding powerful RBAC.
- **Talos + KubeVirt:** Talos is minimal and KubeVirt needs privileged components plus usable KVM/TUN/vhost devices. Verify the actual node before designing an Omni patch.
- **Single-node resource pressure:** Enforce conservative VM/container caps based on measurement. There is no live migration on one node; do not introduce Longhorn RWX merely for a future feature.
- **RWX/live migration:** KubeVirt live migration requires RWX PVCs. Longhorn RWX is NFS share-manager based; this repository's operational notes warn that share-manager mounts can hang Talos reboots. Validate another storage/migration design only after multi-node capacity exists.
- **Windows licensing/sysprep:** Keep golden image out of git, import via `DataVolume` `http` or `pvc` clone, document in SOPS.
- **Streaming perf:** use KasmVNC for containers and prove browser RDP through Guacamole for VMs. KubeVirt VNC is a console/admin mechanism, not the primary end-user route.
- **Security:** authenticate and authorize requests server-side; hide catalog entries in the SPA for UX only, never as enforcement. Audit API lifecycle actions in Loki.

## 8. What Not to Build Yet

Separate `pyos`/`router` ecosystem, Mongo/Memcached, per-workspace DB, ZTNA/OpenZiti, vSphere instant-clone, full Kasm manager, VM pools, GPU, RWX/live migration, and Kubernetes ephemeral-container application launching. Add only when the smaller workplace API + ordinary Pods/VMs prove insufficient.

## 9. Next Steps

1. Replace direct browser Kubernetes API access with the workplace API.
2. Add per-entry persistence/lifecycle policy and conservative resource limits.
3. Run the KubeVirt/CDI Linux capability spike on the actual Talos node.
4. Prove Guacamole browser RDP to a fixed Linux VM.
5. Integrate vetted Linux VM templates, then Windows.

---
*Reviewed against the deployed Chacdn flow, KubeVirt installation/live-migration guidance, and the repository's Talos/Longhorn operational notes. ponytail: keep one catalog and reuse Traefik/Keycloak/Longhorn; add the smallest server-side API before powerful VM provisioning, and prove KubeVirt/RDP before product integration.*
