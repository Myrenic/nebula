# CNI migration Flannel -> Cilium, 18-19 September 2026

Started 18-09 21:22. Cluster fully healthy on 19-09 06:30, all three nodes Ready
and no faulty volume.

## Outcome

**Cilium is the CNI and NetworkPolicy is enforced.** A test pod in `services` can
no longer reach `mushroom-finder-postgres:5432` or aiostreams. Under Flannel it
could, and that is why this migration was needed.

## What was done

1. `omnictl cluster template sync` with patch `600-disable-flannel-cni`
   (`cluster.network.cni.name: none`) and the Cilium manifest (CRDs + chart in
   one file, see `omni/cilium/`).
2. Removed the kube-flannel DaemonSet by hand; on an existing cluster `cni: none`
   does not remove it. Talos did not recreate it.
3. Cilium took over: CiliumEndpoints for the pods, new pods get an IP, DNS works.

## What went wrong

### The NVMe patch was in the wrong place (the real cause)

The cluster has three control-plane machines, and they are not equal:

| Machine | Platform | Disks |
|---|---|---|
| `340932a1-baea-49ac-8bc0-282a554e87e6` | `nocloud` (Proxmox VM) | 1 disk |
| `4c4c4544-004c-4810-805a-b3c04f514433` | `metal` (Dell) | several, including NVMe |
| `4c4c4544-0053-5a10-8054-c7c04f333933` | `metal` (Dell) | several, including NVMe |

The patch `500-extra-disk-nvme0n1-longhorn` hung on the **control-plane set** and
was therefore applied to the VM as well, where `/dev/nvme0n1` does not exist. The
`UserDiskConfigController` kept failing on that, and because of it the node could
not set up its ephemeral partition and the writable overlay:

```
block.UserDiskConfigController: error processing user disk /dev/nvme0n1:
  lstat /dev/nvme0n1: no such file or directory
k8s.KubeletServiceController: error writing kubelet PKI:
  open /etc/kubernetes/bootstrap-kubeconfig: read-only file system
/proc/mounts: / overlay ro, lowerdir+=/layers/layer0,...     <- no upperdir
```

Without a writable root kubelet does not start, and so the node stopped taking
part. The XFS quotacheck errors on `/dev/vda5` were a consequence of this, not
disk damage: the VM's disk was never broken.

**The first diagnosis was wrong.** I thought the VM had lost its NVMe and went
looking in hardware, while the patch was pointing at a disk the VM never had. The
second reboot therefore did not help.

**Fix:** moved the patch from the control-plane set to the two bare-metal
`Machine` documents (with its own `idOverride` per machine). The VM no longer
gets it. After the sync `sz9` rebooted correctly straight away and came back
Ready.

### Pods with a Flannel sandbox

Pods created during the transition got a network sandbox from Flannel. When
Flannel was gone, their network was broken:

```
plugin type="flannel" failed (add):
failed to load flannel 'subnet.env': /run/flannel/subnet.env: no such file
```

That hit `longhorn-csi-plugin` and `longhorn-manager`. Consequence: the CSI
controllers went to `0/3`, the Longhorn node became `Ready=False` and no volumes
could be attached any more, so no pod with a volume started.

**Fix:** restarted `longhorn-csi-plugin`, `longhorn-manager` and the four
CSI-controller deployments, so they got a Cilium sandbox. In addition: force
deleted pods on the unreachable node, cleaned up old `VolumeAttachment` objects
and removed 204 leftover `Failed`/`NodeShutdown` pods.

Beyond that, `oauth2-proxy` (stuck on OIDC discovery) and `helm-controller`
(panic while reading a corrupted certificate) were broken; both fixed with a
fresh pod.

## Final state

| Component | Status |
|---|---|
| Nodes | 3 of 3 Ready |
| Cilium | active, agents on all nodes |
| NetworkPolicy | enforced (tested) |
| Longhorn | 80 of 80 volumes healthy, 0 faulted |
| Deployments | all ready |
| Flux | 29 of 29 kustomizations Ready |
| aiostreams | data intact, no loss |

## Lessons

1. **Never hang a disk patch on a machine set with unequal machines.** Put it on
   the `Machine` documents that actually have the device. A non-existent device
   keeps the whole node down.
2. **After a CNI switch, pods created during the transition have to be
   recreated.** Explicitly restart the DaemonSets that carry the infrastructure
   (CSI, Longhorn), and the controllers that stayed stuck.
3. On an existing cluster the Flannel DaemonSet has to go by hand; on a fresh
   bootstrap with `cni: none` it never appears.
4. Count on one node not coming back. With 3 nodes and 1 down you should not just
   reboot the second one: you lose quorum.
5. Do not do this while asleep. It ended well, but there were hours in which the
   cluster ran on 2 of 3 nodes and nobody could intervene.
