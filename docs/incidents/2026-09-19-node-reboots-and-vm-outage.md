# 2026-09-19: node reboots and the VM outage

Two things from the same session: a Traefik cleanup that was committed, and a VM
that was unschedulable for nine hours and recovered on its own.

## 1. What changed (committed, `847f75d`)

`kubernetes/apps/network/traefik/base/deployment.yaml`:

- `--ping=true` plus a `readinessProbe`/`livenessProbe` on `/ping` (containerPort
  `traefik` = 8080). **There were no probes at all**, so a stuck Traefik kept
  receiving traffic.
- `strategy.rollingUpdate.maxUnavailable: 0` (was `1`) + `maxSurge: 1`, plus
  `terminationGracePeriodSeconds: 30` and a `preStop` sleep -> no downtime during
  updates.

`kubernetes/apps/network/traefik/base/volumes.yaml`: **deleted**, and removed from
`kustomization.yaml`.

- `traefik-acme-pvc` was mounted by **nobody** (verified across all pods).
- It was `ReadWriteMany` on `longhorn` — so a Longhorn share-manager, the type of
  volume that is known in this repo as a reboot-hang risk.
- Certificates come from cert-manager with Cloudflare DNS-01 (`domain-0-prod`),
  so Traefik's own ACME (`certResolver`) was not in use anywhere. Dead weight.
- After the Flux prune the PV stayed behind (`Retain`): removed by hand
  (`longhorn.io/volume-name=traefik-acme` + the PV `pvc-e800804e-...`).

Also cleaned up: 7 `Completed` traefik pods (leftovers from 30 Aug) and the
cluster-wide Succeeded/Failed pods. The cluster was 121 Running / 1 Pending after
that.

**Why those leftovers stay around:** kube-controller-manager only cleans up
terminated pods above `terminated-pod-gc-threshold` (default 12500), and old
ReplicaSets stay because of `revisionHistoryLimit: 10`. To get rid of this
structurally: lower `cluster.controllerManager.config.terminated-pod-gc-threshold`
in the machine config, or set `revisionHistoryLimit` low on busy Deployments. Not
done now (YAGNI).

## 2. Incident: VM `ws-ubuntu-vm-uec8434ac` was down (solved, by itself)

Symptom: VM `ErrorUnschedulable` for 9 hours, virt-launcher `Pending`.

Cause chain (proven, not guessed):

1. **All three nodes had recently restarted** — uptime via
   `talosctl read /proc/uptime`: `7uv-y3y` 06:11, `sz9-1vs` 06:20, `45w-c87`
   07:07. The BootID of 45w-c87 changed (`a063c23d` -> `c1f8efe4`), so a real
   reboot, not a kubelet restart.
2. On `45w-c87` `virt-handler` stayed unhealthy after that -> KubeVirt sets
   `kubevirt.io/schedulable=false` on that node.
3. The VM has `nodeSelector: kubernetes.io/hostname=talos-45w-c87` -> no longer
   placeable anywhere.
4. During the reboot: Longhorn node `45w-c87` `Ready=False` (`ManagerPodDown`),
   5 replicas `stopped`.

Ruled out (verified, not assumed):

- Network is **not** the cause: 30/30 connections to all three API servers
  (`10.0.50.116/.228/.218:6443`) from a pod on `45w-c87`, plus 7/7 to the VIP
  `10.96.0.1:443`.
- No NetworkPolicy in `kubevirt`.
- No Talos upgrade: the Omni cluster `default/talos-default` is on **1.13.8** and
  kubelet reports `Talos (v1.13.8)`.
  Note: `talosctl version` also prints the client version (1.13.9) — do not take
  that for the node version.

Recovery was automatic once the node finished booting: longhorn-manager back,
virt-handler 1/1, label `true` again, all 9 volumes `attached` + `healthy`, VM
`Running`.

**Open:** why those three reboots? Not by me, and no upgrade. Probably the rollout
of the corrected NVMe/machine-config patches. Talos keeps no logs of the previous
boot, so the cause can no longer be established — but it is worth finding out
whether this comes back.
