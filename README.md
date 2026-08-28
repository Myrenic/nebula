# Testlab Cluster

Kubernetes homelab managed by [Flux CD](https://fluxcd.io/) with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) encryption.

## Bootstrap

```bash
# 1. Install Flux
kubectl apply -f https://github.com/fluxcd/flux2/releases/download/v2.7.5/install.yaml

# 2. Create the SOPS age secret (for decrypting secrets in-repo)
cat age.agekey | kubectl create secret generic sops-age \
  --namespace=flux-system --from-file=age.agekey=/dev/stdin

# 3. Apply the Git repo credentials secret
sops -d ./kubernetes/apps/flux-system/flux-instance/flux-system-secret.sops.yaml \
  | kubectl apply -f -

# 4. Apply the Flux sync configuration
kustomize build ./kubernetes/apps/flux-system/flux-instance | kubectl apply -f -

# 5. Wait — Flux reconciles everything else automatically
flux get kustomizations --watch
```

## Infra automation runner

OpenTofu automation runs on a self-hosted GitHub Actions runner deployed in-cluster by Flux (`kubernetes/apps/dev-platform/github-runner`).
Pull requests that touch `infrastructure/**` or `kubernetes/**` now run changed-stack OpenTofu validation, provisioning syntax checks, and `kustomize build` before merge.

Create the GitHub token secret used by ARC (runner registration/auth) in `flux-system`:

```bash
kubectl -n flux-system create secret generic arc-github-auth \
  --from-literal=github_token='<github_pat_with_repo_admin_scope>'
```

The runner mounts `sops-age` directly from `flux-system`, so `terraform/infra.json` decryption stays in-cluster and does not require passing the age key through GitHub secrets.

## HA PDCA Loop

Target for this homelab is not strict 100% uptime; it is predictable self-healing after failures.

- **Plan (weekly + after major changes):** pick 2-3 critical apps, confirm Longhorn replica policy matches risk, and ensure Velero backups are recent (`velero backup get`).
- **Do (monthly drill):** run the 2-of-3 node failure drill below and capture timing/results in your ops notes.
- **Check (after each drill/change):** verify Flux reconciliation is clean, Longhorn volumes rebuild, and critical apps recover without manual YAML edits.
- **Act (same day):** adjust Helm values/replica placement/backup schedules, commit to Git, and let Flux apply. Re-run the drill on the next cadence.

Repeat cadence: **weekly Plan/Check**, **monthly Do drill**, and **immediately after cluster/storage/network upgrades**.

### Failure drill: 2 of 3 nodes unavailable

1. **Pre-check**
   - `kubectl get nodes`
   - `flux get kustomizations -A`
   - `velero backup get | head`
   - Confirm at least one stateless app and one stateful app (Longhorn PVC) are healthy.
2. **Create a restore point**
   - `velero backup create pre-ha-drill-$(date +%Y%m%d%H%M) --wait`
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
   - `kubectl get volumes -n longhorn-system`
   - Check critical app endpoints and confirm Flux is still reconciling.
6. **Rollback / recovery**
   - Power nodes back on, then `kubectl uncordon <node-a> <node-b>`.
   - Wait for Longhorn replica rebuild and pods to rebalance.
   - If a stateful app does not recover automatically, use the app restore procedure in **Restore an individual app**.

## Restore from Backup

Velero backs up to Azure Blob Storage (`velero76b1f66a064d` / container `velero`).
Daily backups are staggered at 03:00, 03:10, 03:20, and 03:40 (7-day retention).
Monthly backups are staggered at 05:00, 05:10, 05:20, and 05:40 on the 1st (60-day retention).
Backup operations are available in the Velero UI via `https://backups.${SECRET_DOMAIN_0}` (OAuth2-protected).

Velero is hardened to self-heal after host trouble:

- `velero` runs **2 replicas with hard node anti-affinity/topology spread**, so one flaky node should not take out both backup controllers.
- `velero-ui` runs **2 replicas with hard node spread and a long startup probe**, so slow cold starts after a reboot do not turn into a liveness-loop.
- Flux/Helm are allowed a longer timeout for `velero-ui`, because a cold reboot can
  legitimately leave it warming up for **10-15 minutes** before it becomes Ready.

### Check Velero after a host reboot

Use the backup storage location as the source-of-truth signal:

```bash
kubectl get pods -n velero -o wide
kubectl get deploy -n velero velero velero-ui
kubectl get backupstoragelocation/default -n velero
```

If `STATUS.phase=Available`, backups/restores are usable even if one replica is still
coming back. **Do not wait for every Velero pod to become Ready** during cluster
recovery; with hard anti-affinity, the second replica can stay `Pending` until another
node is schedulable again.

If Velero or the UI is still unhealthy after ~20 minutes on a healthy cluster:

```bash
flux reconcile kustomization velero -n flux-system --with-source
flux reconcile kustomization velero-ui -n flux-system --with-source

kubectl rollout restart deployment/velero -n velero
kubectl rollout restart deployment/velero-ui -n velero

kubectl wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default \
  -n velero --timeout=300s
```

Useful diagnostics:

```bash
kubectl logs -n velero deployment/velero --tail=200
kubectl logs -n velero deployment/velero-ui --previous --tail=200
kubectl describe pod -n velero -l app.kubernetes.io/instance=velero-ui
```

### Restore an individual app (e.g. aiostreams)

This is the reliable procedure for restoring a single app's PVC data. Velero uses
kopia (pod volume backup) and **requires the pod to start with a `restore-wait` init
container** that it injects at restore time. If the Deployment creates a pod first,
the kopia restore will stall. Follow these steps to avoid that.

```bash
APP=aiostreams
NS=services

# 1. Suspend Flux so it doesn't fight the restore
flux suspend kustomization $APP -n flux-system
flux suspend helmrelease $APP -n $NS

# 2. Scale down and delete the Deployment entirely (prevents Deployment from
#    recreating a pod before Velero can inject the restore-wait init container)
kubectl scale deployment $APP -n $NS --replicas=0
kubectl delete deployment $APP -n $NS

# 3. Delete the PVC so Velero recreates it fresh
kubectl delete pvc $APP -n $NS

# 4. Find the backup to restore from
velero backup get | grep $APP

# 5. Check the real Velero health signal. If the backup storage location stays
#    Unavailable for >10 minutes after the cluster is otherwise healthy, force
#    a reconcile and restart the deployment.
kubectl get backupstoragelocation/default -n velero
# If PHASE != Available for >10m:
flux reconcile kustomization velero -n flux-system --with-source
kubectl rollout restart deployment/velero -n velero
kubectl wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default \
  -n velero --timeout=300s

# 6. Run the restore — do NOT use --existing-resource-policy update, as that
#    causes Velero to update the existing Deployment instead of creating the pod
#    directly (which breaks the restore-wait init container injection)
velero restore create --from-backup <backup-name> --wait

# 7. Monitor: Velero creates the PVC, then a pod with the restore-wait init
#    container, the node-agent restores kopia data, then the app starts
kubectl get pods -n $NS -w

# 8. Resume Flux once the pod is Running
flux resume kustomization $APP -n flux-system
flux resume helmrelease $APP -n $NS
```

### Troubleshooting restore issues

**Restore stuck in `New` phase (rare)**

If a restore stays in `New` for more than ~5 minutes with no activity in
`kubectl logs -n velero deployment/velero`, recycle the deployment:

```bash
kubectl rollout restart deployment/velero -n velero
```

The new pods pick up in-flight `New` restores immediately.

**BSL shows `Unavailable` (`input/output error` writing credentials)**

The Azure plugin writes a temp credential file to `/tmp` inside the velero container.
Velero now runs with two replicas and hard node spread, so a single unhealthy node
usually self-recovers without intervention. If BSL is still not `Available` after
~10 minutes on an otherwise healthy cluster, reconcile and restart:

```bash
flux reconcile kustomization velero -n flux-system --with-source
kubectl rollout restart deployment/velero -n velero
kubectl wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default \
  -n velero --timeout=300s
```

**Velero UI stuck in `CrashLoopBackOff` after a host reboot**

The UI now runs two replicas with a startup probe, so it should tolerate slow cold
starts while the cluster API and Velero settle. A cold reboot can still leave it
warming up for 10-15 minutes. If both replicas stay unavailable for more than
~20 minutes:

```bash
flux reconcile kustomization velero-ui -n flux-system --with-source
kubectl rollout restart deployment/velero-ui -n velero
kubectl logs -n velero deployment/velero-ui --previous --tail=200
```

**Kopia PodVolumeRestore stuck / `shouldProcess` returns false**

Velero's advanced kopia controller skips a PVR if the target pod is not running the
`restore-wait` init container. This happens when:
- `--existing-resource-policy update` was used (Deployment updates instead of Velero creating the pod)
- The pod was force-deleted before the restore completed

**Fix:** delete the restore, delete the Deployment and PVC, and re-run without
`--existing-resource-policy update` (step 6 above).

### Full-cluster restore (disaster recovery)

```bash
# 1. Bootstrap Flux (steps 1–4 in Bootstrap section above)
# 2. Wait for the backup storage location to come back
kubectl wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/default \
  -n velero --timeout=300s
# 3. List backups and pick one
velero backup get
# 4. Restore
velero restore create --from-backup <backup-name> --wait
velero restore describe <restore-name> --details
```
