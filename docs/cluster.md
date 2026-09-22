# Cluster definition (`talos-default`)

This is the source of truth for cluster `talos-default`: the cluster template
Omni applies, plus the Cilium manifests that belong with it.

Omni resets the machine config of the nodes to what is in the template. So never
change anything directly with `talosctl` on a node: it gets rolled back.
Everything belongs here.

**A change to the machine config makes all nodes reboot.** Count on 5-15 minutes
in which the cluster is completely gone, including the VMs.

## Files

| File | What |
|---|---|
| `cluster-template.yaml` | The cluster template: machines, patches and the Cilium manifest reference |
| `cilium/values.yaml` | Helm values for Cilium (the source) |
| `cilium/generate.sh` | Generates `cilium-install.yaml` from those values + the CRDs |
| `cilium/cilium-install.yaml` | Generated. CRDs plus the Cilium chart in one file |

## Applying

The paths in the template are **relative to the template itself**, not to your
working directory. So run from the root of the repo:

```bash
export OMNI_ENDPOINT=https://omni.tuntelder.com/
export OMNI_SERVICE_ACCOUNT_KEY=...        # service account key

omnictl cluster template validate --file omni/cluster-template.yaml
omnictl cluster template render   --file omni/cluster-template.yaml >/dev/null
omnictl cluster template diff     --file omni/cluster-template.yaml
omnictl cluster template sync     --file omni/cluster-template.yaml
```

Note: `validate` does **not** check whether the manifest files exist. Only
`render` does that. If `render` passes, the path is right.

### Converting an existing cluster (not just a bootstrap)

On a fresh bootstrap with `cni: none` Flannel never appears. On an existing
cluster the DaemonSet stays and you have to remove it yourself, otherwise two
CNIs run side by side:

```bash
kubectl -n kube-system delete ds kube-flannel
```

After that, pods created during the transition have to be recreated, because
their network sandbox is still Flannel's:

```bash
kubectl -n storage rollout restart ds longhorn-csi-plugin
kubectl -n storage rollout restart ds longhorn-manager
kubectl -n storage rollout restart deploy csi-attacher csi-provisioner csi-resizer csi-snapshotter
```

Without that step the CSI controllers stay on `0/3`, the Longhorn node becomes
`Ready=False` and no pod with a volume starts. The full aftermath is in
[`incidents/2026-09-18-flannel-to-cilium.md`](incidents/2026-09-18-flannel-to-cilium.md).

## Cilium

Cilium is the CNI; Flannel is off via patch `600-disable-flannel-cni`. Cilium is
applied as a `mode: one-time` manifest: Omni installs it at bootstrap, after
which Cilium manages itself. An upgrade is a deliberate action (`./generate.sh`
with a new version, then syncing).

### The CRDs are bundled on purpose

The Cilium Helm chart contains **no CRDs**. `helm show crds cilium/cilium` gives
zero lines and the chart has no `crds/` directory; it does have a
`crdWaitTimeout` and waits until they exist. Without CRDs `CiliumNetworkPolicy`
does not exist and the policy layer **silently does nothing** — exactly the
situation we came from with Flannel. That is why the CRDs are in
`cilium-install.yaml`, ahead of the chart (within one file the order is
guaranteed).

### Talos-specific settings

| Setting | Why |
|---|---|
| `ipam.mode=kubernetes` | reuses the per-node podCIDR that already exists |
| `kubeProxyReplacement=false` | kube-proxy keeps doing service routing; smaller step |
| `bpf.hostLegacyRouting=true` | **required**: Talos forwards kube-dns to the host DNS, which collides with Cilium's eBPF host routing, and without this CoreDNS does not work |
| capabilities without `SYS_MODULE` | Talos does not allow workloads to load kernel modules |
| `cgroup.autoMount.enabled=false` | Talos already mounts cgroupv2 and bpffs |

After generating, `generate.sh` checks for `enable-host-legacy-routing`,
`ipam: kubernetes`, the presence of `ciliumnetworkpolicies` and the absence of
`SYS_MODULE`. If one of those checks fails, the script stops.

### Upgrading

```bash
cd omni/cilium
CILIUM_VERSION=1.20.3 ./generate.sh
cd ../..
git diff omni/cilium                    # look at what changes
omnictl cluster template sync --file omni/cluster-template.yaml
```

## Machines are not equal

The control plane consists of two bare-metal Dells and one Proxmox VM
(`talos.platform=nocloud`). Only the Dells have `/dev/nvme0n1`.

Machine-specific hardware therefore belongs in a **`Machine` document**, not on
the `ControlPlane` set. The NVMe/Longhorn patch was set-wide at first, was
applied to the VM as well, and kept that node down: the failing
`UserDiskConfigController` prevented the writable overlay, after which kubelet
no longer started. See
[`incidents/2026-09-18-flannel-to-cilium.md`](incidents/2026-09-18-flannel-to-cilium.md).

```yaml
kind: Machine
name: 4c4c4544-004c-4810-805a-b3c04f514433   # bare metal
patches:
  - idOverride: 500-nvme-longhorn2-baremetal-1
    inline: |
      machine:
        disks:
          - device: /dev/nvme0n1
            partitions:
              - size: 0
                mountpoint: /var/mnt/longhorn2
```

Two machines cannot have the same `idOverride`; give each machine its own ID.

## Network policy

NetworkPolicies did nothing under Flannel. With Cilium they become active,
including the four that come with Flux (`flux-system/allow-*`) and the three of
the mushroom app.

Roll out new policies in stages: first Cilium in audit mode, then look with
Hubble at what would be dropped, and only then enforce.

## Verification

```bash
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium
cilium status --wait
cilium connectivity test
omnictl get clusterkubernetesmanifestsstatuses talos-default
```

## Rollback

1. Remove patch `600-disable-flannel-cni` from `cluster-template.yaml`.
2. `omnictl cluster template sync --file omni/cluster-template.yaml`
3. Nodes reboot; Flannel comes back.
4. Cleaning up Cilium afterwards can be done with `cilium uninstall`.

Velero was not available during the switch (backupstoragelocation
`Unavailable`), so no extra snapshot was made. A reboot does not delete Longhorn
volumes, but it is good to know that that safety net was not there.

## Omni itself

Omni is self-hosted: it runs on the Proxmox host `10.0.50.11`, inside LXC 108
(`sidero-omni`), as a Docker container. There is no compose file - it is started by
`/root/omni-deploy/run-omni.sh`, which was reconstructed from the running container
(image, mounts, devices, capabilities and every flag) so that upgrades stop being
guesswork:

```bash
cd /root/omni-deploy
./run-omni.sh v1.12.1     # recreate the container on a given tag
```

Its state lives on the host and survives recreating the container:

| Path | What |
| --- | --- |
| `/root/etcd` | embedded etcd - Omni's database, the thing that must not be lost |
| `/root/sqlite` | `omni.db` (audit/backup state) |
| `/root/backups` | etcd snapshots and the pre-upgrade container config dump |
| `/root/bin/etcdctl` | version-matched CLI for taking those snapshots |

### Two things the container cannot run without

`siderolink` is WireGuard, so the container needs `/dev/net/tun` **and**
`CAP_NET_ADMIN`, both passed explicitly by `run-omni.sh`:

```
--device /dev/net/tun:/dev/net/tun:rwm --cap-add=CAP_NET_ADMIN
```

Without them, Omni 1.11 and later exit at startup with

```
Error: failed to run server: error initializing wgDevice: error creating tun device:
CreateTUN("siderolink") failed; /dev/net/tun does not exist
```

Older versions initialised the device lazily, which is why the missing device only
surfaced on the first upgrade. The LXC config itself already passes the device
(`lxc.cgroup2.devices.allow: c 10:200 rwm` plus a mount entry).

### Upgrading

Omni supports one minor version at a time, and database migrations are not
reversible, so there is no way back except restoring a snapshot. A version that
supports a newer Talos is worth the two hops:

| Omni | Note |
| --- | --- |
| < 1.11 | does not support Talos 1.14 |
| 1.11.0 | first release with Talos 1.14 support; backend API v3 |
| 1.12.1 | current |

```bash
# 0. snapshot first - this is the only rollback that exists
/root/bin/etcdctl --endpoints=http://localhost:2379 snapshot save /root/backups/omni-$(date +%F).db

# 1. check the container does not keep etcd inside itself (it must not)
docker inspect omni --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -qEx '/_out(/etcd)?' \
  && echo "etcd is on the host, safe to recreate the container" \
  || echo "STOP: etcd lives in the container, follow the restore-omni-database guide first"

# 2. one minor per hop, watching the migration logs
docker pull ghcr.io/siderolabs/omni:v1.11.0 && ./run-omni.sh v1.11.0
docker logs omni --tail 50
docker pull ghcr.io/siderolabs/omni:v1.12.1 && ./run-omni.sh v1.12.1
```

`omnictl` must match the server: the backend API version changes between minors, and
a mismatched client fails with `client API version mismatch`. The server serves a
matching build itself, which is also how the CLI on the workstation is updated:

```bash
curl -sSfL -o /usr/local/bin/omnictl https://omni.tuntelder.com/api/omnictl/omnictl-linux-amd64
chmod +x /usr/local/bin/omnictl && omnictl --version
```

### Verifying an upgrade

```bash
docker ps --filter name=omni                      # Up, not Restarting
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost/
ip link show siderolink                           # the WireGuard interface
ping6 -c1 fdae:41e4:649b:9303:<machine-address>   # machines over the tunnel
docker logs omni --since 60s | grep -c "reconcile succeeded"
```

Expect the UI to answer, `siderolink` up, all machines answering, and a steady
stream of successful reconciles. A handful of `i/o timeout` entries for machine
addresses right after a restart is the tunnel re-establishing itself; they should
stop within a minute or two.

### The Proxmox infrastructure provider has a stale key

`proxmox-provider-omni-infra-provider-proxmox-1` crash-loops (restart count in the
tens of thousands) with:

```
Error: failed to get Omni system version: rpc error: code = Unauthenticated desc = invalid signature
```

Omni resolves the identity `proxmox`, so the provider is registered - it is the key
that no longer matches. The provider authenticates with an *infrastructure provider
key* (not a service account key), and it has to be registered again in Omni and
pasted into `/root/proxmox-provider/docker-compose.yml`, which also still pins the
provider image to `latest` (v0.3.0 is the current release).

### Draining a node that runs Longhorn replicas

Omni drains a node before it reboots it for a Talos upgrade, and Longhorn's default
`node-drain-policy` (`block-if-contains-last-replica`) refuses to evict the
instance-manager of a node holding the only replica of any volume. The drain then
retries that eviction until its client-side rate limiter runs out of time, and the
upgrade aborts with an error that names neither Longhorn nor the volume:

```
upgrade failed: cordon/drain before reboot failed: failed to drain node "talos-7uv-y3y":
error when evicting pods/"instance-manager-…" -n "storage":
client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline
```

Look at `kubectl -n storage get pdb`: instance-manager entries with
`disruptionsAllowed: 0` are the blockers - that node holds a last replica. Two ways out:

```bash
# Option A - allow eviction for the duration of the maintenance, then restore:
kubectl -n storage patch settings.longhorn.io node-drain-policy --type merge \
  -p '{"value":"always-allow"}'
#   ...upgrade the node...
kubectl -n storage patch settings.longhorn.io node-drain-policy --type merge \
  -p '{"value":"block-if-contains-last-replica"}'
```

Option B removes the cause: a second replica on the volumes that only have one. Today
that is `frigate-media`, which the replica-adjuster deliberately skips, and it lives on
the Intel-iGPU node - so it blocks every drain of that node on its own. A second
replica costs disk and buys a drain that does not depend on the policy.

Either way the volumes on the node being rebooted are unavailable while it is down.
That is expected, and Longhorn recovers them: after the reboot `frigate-media` came
back faulted, and `autoSalvage` rebuilt its engine from the on-disk replica on the next
mount. The same reboot left 98 dead coturn pod objects behind (its pods are pinned to
one node for its public IP); those clean up with

```bash
kubectl -n services delete pod --field-selector=status.phase=Failed
```

Omni upgrades one machine at a time (it serialises them with an upgrade lock) and
uncordons the node itself once the machine is back, so a half-finished cluster upgrade
just needs to be retried - there is no state to clean up by hand.
