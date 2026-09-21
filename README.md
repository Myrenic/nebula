# Testlab Cluster

Kubernetes homelab managed by [Flux CD](https://fluxcd.io/) with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) encryption.

## Bootstrap

The only prerequisite on the machine running the bootstrap is `kubectl`/`kustomize`, a kubeconfig for the target cluster, and the SOPS age key (kept outside this repo, e.g. in the Orbit repo - `age.agekey` is gitignored here on purpose).

```bash
# 1. Install Flux (controllers + CRDs) and the Git sync config in one shot.
#    This is the only thing the bootstrap file does; it is intentionally
#    self-contained and does NOT include secrets.
kubectl apply -k kubernetes/bootstrap

# 2. Give Flux the age key so the root Kustomization can decrypt the
#    .sops.yaml files (spec.decryption is already configured on it).
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=<path-to-age.agekey>

# 3. Watch Flux reconcile everything else.
flux get kustomizations --watch
```

Notes:

- The `GitRepository` clones `https://github.com/myrenic/nebula` anonymously (the repo is public). No deploy key is involved; if the repo ever becomes private, switch the URL in `kubernetes/apps/flux-system/flux-instance/gotk-sync.yaml` to `ssh://git@github.com/myrenic/nebula` and apply a decrypted `flux-system` deploy-key secret manually.
- `kubernetes/apps/flux-system/flux-instance/flux-system-secret.sops.yaml` is kept only as an encrypted backup of the old deploy key and is not part of any kustomization.

## Secrets

All cluster secrets live in **`kubernetes/apps/common/cluster-secrets.sops.yaml`** (Secret `cluster-secrets` in `flux-system`). Workloads consume them in one of two ways:

- Flux `postBuild.substituteFrom` injects `${VAR}` placeholders in manifests at build time (see `kubernetes/apps/cert-manager/cert-manager/issuers/cloudflare-issuer-secret.yaml` for an example). The rendered object holds the real value; git holds only the placeholder. App repositories listed below use the same mechanism with this cluster's `cluster-secrets`.
- Apps that read a whole secret (`envFrom`, `existingSecret`) reference the secret directly.

Rules for adding a secret:

1. Add the key to `cluster-secrets.sops.yaml` with `sops set '["stringData"]["KEY"]' '"value"' kubernetes/apps/common/cluster-secrets.sops.yaml`.
2. Never commit a plaintext value. A file named `*.sops.yaml` **must** contain a `sops:` block and `ENC[` values; CI enforces this (the `sops audit` job).

## App repositories

Two apps keep their own code and manifests, outside this repository:

| App | Repository | URL | Consumed by |
| --- | --- | --- | --- |
| mytops | `Myrenic/mytops` | `https://apps.${SECRET_DOMAIN_0}` | `kubernetes/apps/services/mytops/` |
| mushroom-finder | `Myrenic/mushroom-finder` | `https://mushrooms.${SECRET_DOMAIN_0}` | `kubernetes/apps/services/mushroom-finder/` |

Each directory here contains only the deployment contract - a `GitRepository` (`source.yaml`) plus a `Kustomization` (`ks.yaml`) that points at `./base` in that repository, sets `targetNamespace` and substitutes `${...}` from `cluster-secrets`. Their own CI builds the manifests, rebuilds the generated ConfigMap bundles and asserts they are committed (`git diff --exit-code`), and Renovate runs there too.

What stays here, because it is platform rather than app:

- ingress routes and the auth chain (`network/ingressroutes/`), including the cross-namespace control RBAC for mytops
- the `storage/mytops-rbac.yaml` grant for deleting Longhorn volumes during VM teardown (it must live in a Kustomization without `targetNamespace`, otherwise the namespace is overridden and the grant lands in the wrong namespace)
- the secrets themselves (`cluster-secrets`), which the app repositories only reference by placeholder

The Keycloak realm for both apps is `mytops`.


## CI

`.github/workflows/validate-changes.yaml` runs on GitHub-hosted runners and gates every PR that touches `kubernetes/**`:

- `kubectl kustomize kubernetes/apps` and `kubernetes/bootstrap` must build.
- Every `*.sops.yaml` under `kubernetes/` must be encrypted.
- Every `IngressRoute` in `kubernetes/apps/network/ingressroutes` must either carry an authentication middleware (`oauth2-proxy-auth` / `lan-only`) or explicitly declare `testlab.io/exposure: public`.

`.github/workflows/renovate.yml` runs Renovate for `flux`, `kubernetes` and `github-actions` dependencies.

## HA PDCA Loop

Target for this homelab is not strict 100% uptime; it is predictable self-healing after failures.

- **Plan (weekly + after major changes):** pick 2-3 critical apps, confirm the Longhorn replica policy matches risk, and confirm a stateful app survives a pod reschedule.
- **Do (monthly drill):** run the 2-of-3 node failure drill below and capture timing/results in your ops notes.
- **Check (after each drill/change):** verify Flux reconciliation is clean, Longhorn volumes rebuild, and critical apps recover without manual YAML edits.
- **Act (same day):** adjust Helm values/replica placement/backup schedules, commit to Git, and let Flux apply. Re-run the drill on the next cadence.

Repeat cadence: **weekly Plan/Check**, **monthly Do drill**, and **immediately after cluster/storage/network upgrades**.

### Failure drill: 2 of 3 nodes unavailable

1. **Pre-check**
   - `kubectl get nodes`
   - `flux get kustomizations -A`
   - `kubectl -n storage get volumes.longhorn.io | head` — note healthy/degraded counts.
   - Confirm at least one stateless app and one stateful app (Longhorn PVC) are healthy.
2. **Create a restore point**
   - There is currently **no cluster backup layer** (see [Backups](#backups)), so the restore point is the Longhorn replica set plus the current git revision. Record `git rev-parse HEAD` and the volume state before draining.
3. **Simulate failure**
   - Pick two nodes to take offline.
   - `kubectl cordon <node-a> <node-b>`
   - `kubectl drain <node-a> <node-b> --ignore-daemonsets --delete-emptydir-data --force`
   - Power off or disconnect both nodes.
4. **Continuity expectation (realistic homelab)**
   - Some apps may be briefly unavailable; core ingress/DNS/Flux should recover on the surviving node.
   - Expect degraded capacity/performance, but no prolonged manual babysitting for healthy workloads.
5. **Verify self-healing (10-15 min window)**
   - `kubectl get pods -A -o wide`
   - `kubectl -n storage get volumes.longhorn.io`
   - Check critical app endpoints and confirm Flux is still reconciling.
6. **Rollback / recovery**
   - Power nodes back on, then `kubectl uncordon <node-a> <node-b>`.
   - Wait for Longhorn replica rebuild and pods to rebalance.

## Backups

**There is no backup layer right now.** Velero (with an Azure Blob storage location) was removed after its `backupstoragelocation/default` sat in `Unavailable` for weeks — every scheduled backup had been failing, so it was a false sense of safety rather than a backup. The manifests, the nightly schedules, the restore runbook and the `backups.${SECRET_DOMAIN_0}` route are gone with it.

What that means in practice:

- State lives on Longhorn volumes with `numberOfReplicas: 2` (see [Storage](#storage)); a node loss is survivable, a volume corruption or a bad `kubectl delete` is not.
- Deleted objects are only recoverable from git if they are managed by Flux.
- Do not run the failure drill expecting a restore path.

If a backup layer comes back, it must:

1. Prove `Available` on the storage location before it is trusted — that status, not pod readiness, is the signal.
2. Be verified by an actual restore of one app into a scratch namespace, not by a successful backup run.
3. Keep credentials out of git (SOPS) and out of the admission path of the apps it protects.

## Storage

Longhorn runs with `defaultReplicaCount: 1` and `defaultClassReplicaCount: 1`; the `longhorn-2-replicas` StorageClass is used where a second copy is required. The `longhorn-replica-adjuster` CronJob converges existing volumes to 2 replicas once at least two nodes are `Ready` (`frigate-media` is deliberately excluded), and back to 1 while the cluster is effectively single-node. StorageClasses use `volumeBindingMode: WaitForFirstConsumer` so replicas are placed after the pod is scheduled.

Longhorn volumes use `reclaimPolicy: Retain`, so a deleted PVC leaves a released `volumes.longhorn.io` object behind. Clean those up deliberately:

```bash
kubectl -n storage get pv | grep Released
```

## Access model

Traefik terminates TLS with the cert-manager certificate `domain-0-prod` (Cloudflare DNS-01) and is the only LoadBalancer service (`10.0.50.4`, MetalLB L2 pool `10.0.50.4-10.0.50.6`).

Authentication is `oauth2-proxy` in front of Keycloak (OIDC). Exposure is explicit: every `IngressRoute` either carries `oauth2-proxy-auth` (SSO), `lan-only` (RFC1918 source ranges), or `testlab.io/exposure: public` with a reason in a comment. CI enforces that a route is never accidentally public.

## Restore an individual app from git

Deleting an object and letting Flux reconcile it back is the normal path:

```bash
flux reconcile kustomization <app> -n flux-system --with-source
```

Flux only restores what is in git — data on PVCs is not part of that. When a PVC is deleted, the app comes back with an empty volume.
