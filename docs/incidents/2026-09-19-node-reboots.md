# 2026-09-19: node reboots

Two things from the same session: a Traefik cleanup that was committed, and all
three nodes restarting inside the hour with no upgrade behind it.

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

## 2. All three nodes restarted, cause unknown

Uptime via `talosctl read /proc/uptime`: `7uv-y3y` 06:11, `sz9-1vs` 06:20,
`45w-c87` 07:07. The BootID of `45w-c87` changed (`a063c23d` -> `c1f8efe4`), so a
real reboot, not a kubelet restart.

Ruled out (verified, not assumed):

- No Talos upgrade: the Omni cluster `default/talos-default` is on **1.13.8** and
  kubelet reports `Talos (v1.13.8)`. Note: `talosctl version` also prints the client
  version (1.13.9) — do not take that for the node version. (Those were the versions
  on the day; the cluster has since moved to Talos v1.14.1 and Kubernetes v1.37.0,
  and keeping the documentation level with that is
  [known-issues.md §4](../known-issues.md#4-cluster-versions-can-drift-from-the-documentation-and-the-template).)
- Network is **not** the cause: 30/30 connections to all three API servers
  (`10.0.50.116/.228/.218:6443`) from a pod on `45w-c87`, plus 7/7 to the VIP
  `10.96.0.1:443`.

What a reboot costs, in the order it shows up: the node's Longhorn instance-manager
goes `Ready=False` (`ManagerPodDown`) and its replicas stop until longhorn-manager
is back, and workloads pinned to that node stay `Pending` until it returns. Both
recover on their own: the last reboot left no volume unattached and needed no
manual step.

**Open:** why those three reboots? Not this repository, and no upgrade. Probably the
rollout of the corrected NVMe/machine-config patches. Talos keeps no logs of the
previous boot, so the cause can no longer be established — but it is worth finding
out whether this comes back. It is tracked as
[#36](https://code.tuntelder.com/mtuntelder/nebula/issues/36), and what to capture if
it does is in
[known-issues.md §3](../known-issues.md#3-the-2026-09-19-reboots-are-unexplained).
