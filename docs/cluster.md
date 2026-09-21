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
