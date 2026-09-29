# Sextant test devices

Two small KubeVirt VMs that are real devices in the [Sextant](../sextant/README.md)
fleet: they run the NixOS configuration the fleet's *overlay* generates for
`vm-test-1` and `vm-test-2`, they carry the device agent, they check in, and the
console shows them, their facts and their revision.

They exist because the imaging station cannot reach a guest here. A station PXE
boots its targets and owns DHCP on the segment it boots them from (its own switch
in the reference setup); a KubeVirt guest sits on Cilium's routed pod network with
no broadcast domain, and this cluster has no Multus, no bridge and no secondary
network to give it one. So these two devices take the other road into a fleet -
the one every hand-installed machine takes: the generated configuration is
installed onto them, the credential is written at provisioning time, and the agent
takes it from there. Everything after the install is the same as real hardware,
which is the part worth testing.

## What is where

| Where | What |
| --- | --- |
| The fleet's overlay repository | `fleet.json` (the two devices, group `testlab`, class `vm`), `vm-core.nix` (the headless image recipe), `hardware/kubevirt-vm.nix` (a bootable virtio guest) |
| `base/images.yaml` | The disk store: an RWX volume and the nginx that serves it to CDI, the same shape the workspace images use |
| `base/vm-test-1.yaml`, `base/vm-test-2.yaml` | The two VMs. Each boots a disk CDI imports from that store, with its identity arriving over cloud-init |
| `build-in-cluster.yaml` | The disk build. **Not applied by Flux** - it is a manual, occasional job, marked `# not-applied` for the repository's orphan check |
| `sextant-overlay-netrc` / `vm-test-1-userdata` | The overlay credentials and the per-device credentials. Flux owns the first; the second is created by hand because it is minted by the console and exists nowhere else |

## Bringing them up

### 1. Get the devices into the fleet document

The overlay carries `vm-test-1` and `vm-test-2`; the console reconciles that
repository, so once it has the commit they appear as **provisional** (a record
with no check-in yet - see *Provisional* in the Sextant handbook's lifecycle
page).

### 2. Mint each device's credential

Enrolment is where a device gets its identity, and the credential is shown once:

```sh
TOKEN=<SEXTANT_API_TOKEN from cluster-secrets>
curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
  "https://sextant.${SECRET_DOMAIN_0}/api/v1/devices/vm-test-1/credential"
```

Put each one into the cloud-init Secret the VM reads - the file has to be exactly
the token, with no trailing newline (a credential with one never matches, and the
console says only "unauthorized"):

```sh
kubectl -n kubevirt create secret generic vm-test-1-userdata \
  --from-literal=userdata="#cloud-config
write_files:
  - path: /var/lib/sextant-agent/credential
    owner: root:root
    permissions: '0600'
    content: '<the token from the console>'"
```

### 3. Build the disks

```sh
kubectl apply -f kubernetes/apps/kubevirt/sextant-testlab/build-in-cluster.yaml
kubectl -n kubevirt logs -f job/sextant-testlab-build
```

The job clones the overlay, builds `nixosConfigurations.vm-test-1` (and `-2`) as
qcow2 images and installs them into `sextant-testlab-images`, printing a sha256
and the overlay revision per disk. It is slow the first time - a nix store is
fetched into the container, then the closure, then two disk images - and the
`…-REV` files it writes are how a running VM can be tied back to a commit.

Building needs the node's `/dev/kvm` (nixpkgs' disk-image builder boots a small
VM to install the bootloader), which is why this job is in the cluster at all
rather than on a workstation.

### 4. Let CDI import and the VMs boot

Flux applies the VMs; each one's `DataVolume` imports its qcow2 from the store
and converts it to a raw disk. Watch it:

```sh
kubectl -n kubevirt get dv,vm,vmi
kubectl -n kubevirt get dv vm-test-1-root -o jsonpath='{.status.phase}{"\n"}'
```

The disks currently in the store, as `build-in-cluster.yaml` wrote them:

| Disk | Bytes | Built from |
| --- | --- | --- |
| `vm-test-1.qcow2` | 3 747 741 696 | overlay `53aa2f8`, sha256 `c72d259e…66648a` |
| `vm-test-2.qcow2` | 3 747 479 552 | overlay `53aa2f8`, sha256 `664da137…a84a9fc` |

Each VM's disk is a `DataVolume` of its own (`datavolumes.yaml`), pinned to the
sha256 above, so an import that would boot something else fails instead.
Standalone rather than a template inside the VM on purpose: this cluster's
KubeVirt embeds a DataVolume schema old enough to have no `checksum` field, so a
disk declared inside a VM cannot pin one. Rebuilding writes new disks and new
checksums: update both lines.

An import failing with `404` means the build job has not written that disk yet -
`vm-test-1.qcow2` is what the URL names. Re-running the job and deleting the
DataVolume (`kubectl -n kubevirt delete dv vm-test-1-root`) imports the new disk;
the VM stops while its volume is gone.

### 5. Check in

The console's device page is the answer: `vm-test-1` should move from provisional
to active and start reporting facts, its deployed revision and its posture.

```sh
kubectl -n kubevirt get vmi vm-test-1 -o jsonpath='{.status.phase}{"\n"}'
```

There is no shell here: `kubectl exec` addresses pods, and a VMI is not one - the
way into a guest is `virtctl console -n kubevirt vm-test-1` (serial, no login
unless the user-data adds one) or `virtctl ssh`, which needs a key in the guest.
For a device's own view of itself, use the console: a `diagnostics` intent on the
device page collects a bounded bundle (journal tail, failed units) from the guest
and stores it, sealed, in the observed plane.

### 6. Watch it converge

These devices converge like real ones. `converge.nix` in the overlay points comin
at the fleet's repository, so a commit to `main` (or to the device's ring branch)
is picked up on the next poll and rebuilt in place:

```sh
# read the overlay's current revision, then push something and watch this change
kubectl -n kubevirt get vmi vm-test-1 -o jsonpath='{.status.phase}{"\n"}'
```

The agent reports the revision it was built from, so the console's device page is
the fastest place to see convergence land. The token comin authenticates with is
written by the same user-data as the device credential, from
`vm-test-1-userdata` - see `converge.nix` in the overlay for the path it reads.

## What this path does not do

- **No host key on file.** The console learns a device's SSH host key from the
  *station* at imaging time (`recordHostKey` in the station API), and these
  devices never met one, so their device pages say "No host key recorded - device
  secrets cannot be encrypted for this device" and the agenix recipient path has
  nothing to seal to. Everything else about them is a normal device.
- **No hardware spec.** The same is true of the asset facts a station captures
  (`spec`); the VMs report usage and posture, not a fingerprint.
- **Nothing is imaged.** There is no partitioner, no Secure Boot ceremony and no
  TPM2 sealing here - the disk arrives already built, which is the one step an
  imaging station exists to perform.
- **Org settings the VM image does not declare are skipped, but still listed.**
  The generator skips a setting whose option this image does not have (the
  overlay passes `catalogKeys`), which is why the organisation's enforced
  `secureboot` is not forced onto these VMs. The console's effective-configuration
  panel still resolves it from the scope chain, so a device can read "settings
  due" for something its image deliberately ignores. Per-class catalog export
  (`sextant.lib.exportCatalogFromClassOptions`) is what closes that gap, and it
  needs a device of each class to export from.

## Removing it

```sh
kubectl delete -f build-in-cluster.yaml
kubectl -n kubevirt delete secret vm-test-1-userdata vm-test-2-userdata
# then drop the directory from kubernetes/apps/kubevirt/kustomization.yaml, and
# retire the two devices in the console (the fleet document is their record)
```

The PVC goes with the directory once Flux prunes it; deleting it loses only built
disks, which the build job can reproduce.
