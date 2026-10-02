# Known issues

What is wrong or unexplained today, in one place. Each entry says what it looks
like, what to do, and how it is - or is not - visible. There is no owner column:
for every one of these the honest answer is "whoever is on the cluster next".

Where an entry has been raised as a forge issue, the number is a link to
<https://code.tuntelder.com/mtuntelder/nebula/issues>.

| # | Issue | Status |
| --- | --- | --- |
| 1 | The Proxmox infrastructure provider crash-loops, invisibly to the cluster | Open ([#34](https://code.tuntelder.com/mtuntelder/nebula/issues/34)) |
| 2 | `frigate-media` has one replica and blocks every drain of its node | Open, by design ([#35](https://code.tuntelder.com/mtuntelder/nebula/issues/35)) |
| 3 | The 2026-09-19 reboots are unexplained | Open, not reproducible ([#36](https://code.tuntelder.com/mtuntelder/nebula/issues/36)) |
| 4 | Cluster versions can drift from the deployment docs and the Omni template | Template corrected 2026-10-02, check stays manual |
| 5 | The Velero restore path is documented as drilled but has never been run | Open ([#37](https://code.tuntelder.com/mtuntelder/nebula/issues/37)) |
| 6 | The leaked Cilium CA key is still in the history of both remotes | Key rotated in-cluster 2026-10-02; purge open ([#38](https://code.tuntelder.com/mtuntelder/nebula/issues/38)) |
| 7 | The GitHub copy of this repository is stale and diverged | Open ([#39](https://code.tuntelder.com/mtuntelder/nebula/issues/39)) |
| 8 | The Prometheus volume is 97% full, and three volumes from the retired in-cluster Forgejo are detached | Open, not yet tracked |

## 1. The Proxmox infrastructure provider crash-loops, and nothing in the cluster can see it

**Status:** open, tracked as [#34](https://code.tuntelder.com/mtuntelder/nebula/issues/34).
Restart count in the tens of thousands.

**Looks like:** on the Proxmox host (not in the cluster), `docker ps` shows
`proxmox-provider-omni-infra-provider-proxmox-1` cycling, and `docker logs` repeats:

```
Error: failed to get Omni system version: rpc error: code = Unauthenticated desc = invalid signature
```

**Why it is invisible:** the provider runs as a container on the Proxmox host, not as
a pod. kube-prometheus-stack, the alert rules and Flux all live inside the cluster, so
there is no metric, no probe and no alert that can reach it. The only place it is
visible is the Proxmox host itself.

**What to do:** the provider authenticates with an *infrastructure provider key*, not
a service account key, and that key no longer matches (Omni still resolves the
identity `proxmox`, which is why it looks registered). Register the key again in Omni,
paste it into `/root/proxmox-provider/docker-compose.yml`, and pin that file's image
to `v0.3.0` instead of `latest` while it is open. Then confirm on the host that the
restart counter is not climbing.

Background: [`cluster.md` § The Proxmox infrastructure provider has a stale key](cluster.md#the-proxmox-infrastructure-provider-has-a-stale-key).

## 2. `frigate-media` has one replica, and that replica blocks every drain of its node

**Status:** open, tracked as [#35](https://code.tuntelder.com/mtuntelder/nebula/issues/35),
and deliberate in one half: the volume is excluded from the backup schedules (it is
50 GiB of continuous recordings) and from the replica-adjuster, so converging it to
two replicas is a decision, not an oversight to fix.

**Looks like:** an Omni node drain or Talos upgrade fails with an error naming
neither Longhorn nor the volume:

```
upgrade failed: cordon/drain before reboot failed: failed to drain node "<node>":
error when evicting pods/"instance-manager-…" -n "storage":
client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline
```

`kubectl -n storage get pdb` is the way to see it coming: the `instance-manager` entry
for that node has `disruptionsAllowed: 0`, because Longhorn's default
`node-drain-policy` refuses to evict a last replica.

**What to do:** either stop letting it be the last replica - a second replica costs
disk, and disk is not idle here: Longhorn had 21 volumes, 253 GiB declared and 96.3
GiB actually used at the last read, and the Prometheus volume is at 97% (see §8) - or
accept the workaround for the duration of the maintenance: set `node-drain-policy` to
`always-allow`, do the upgrade, set it back. The volume lives on the Intel-iGPU node,
pinned there with the workload that writes it, so it blocks every drain of that node
on its own.

Background: [`cluster.md` § Draining a node that runs Longhorn replicas](cluster.md#draining-a-node-that-runs-longhorn-replicas).

## 3. The 2026-09-19 reboots are unexplained

**Status:** open, not reproducible since, tracked as
[#36](https://code.tuntelder.com/mtuntelder/nebula/issues/36).

**What happened:** all three nodes restarted inside the hour (uptimes `7uv-y3y`
06:11, `sz9-1vs` 06:20, `45w-c87` 07:07) with no Talos upgrade behind them. The BootID
of `45w-c87` changed, so those were real reboots and not kubelet restarts. Network was
ruled out by measurement (30/30 connections to all three API servers, 7/7 to the
service VIP), and no upgrade was in flight. The likely culprit is the rollout of the
corrected NVMe/machine-config patches, but nothing proves that.

**Why it cannot be diagnosed now:** Talos keeps no logs of the previous boot, so the
evidence is gone the moment the node comes back. A reboot is survivable - Longhorn
recovers, workloads on that node wait - but it is not understood.

**What to do:** treat a recurrence as an incident with a clock on it. Read the node
immediately, before the next one goes:

```bash
talosctl -n <node-ip> dmesg
talosctl -n <node-ip> read /proc/uptime     # how long this boot has been up
```

and compare BootIDs across the three nodes afterwards. If two reboots land close
together, one write-up of what was captured beats three guesses.

Background: [`incidents/2026-09-19-node-reboots.md`](incidents/2026-09-19-node-reboots.md).

## 4. Cluster versions can drift from the documentation and the template

**Status:** the Omni template carries Talos `v1.14.1` and Kubernetes `v1.37.0`, which
is what the cluster runs as of 2026-10-02 - so the drift is closed for now. The check
stays manual: nothing in CI can reach the cluster.

**What it looked like:** the live cluster ran Talos v1.14.1 and Kubernetes v1.37.0
while this documentation and the Omni template still said 1.13.8 and v1.36.3 (the
incident report of 2026-09-19 records the cluster at 1.13.8, which was true when it
was written).

**Why it matters:** `omnictl cluster template sync` makes the cluster match the
template in *both* directions. A template that is behind the machines therefore does
not sit quietly - it is a downgrade attempt, one Talos minor at a time, with
irreversible database migrations behind each hop.

**What to do:** before any sync, read both sides. The commands and what each one
prints are in
[`cluster.md` § Before a sync](cluster.md#before-a-sync-check-the-versions-against-the-cluster).
`omnictl cluster template diff` is the other half of that check and needs a service
account key, which this workstation did not have, so the versions above were read with
`kubectl` and from the template file.

## 5. The Velero restore path is documented as drilled but has never been run

**Status:** open, tracked as [#37](https://code.tuntelder.com/mtuntelder/nebula/issues/37).

**Looks like:** the introduction to the repository says the restore path "has been
drilled rather than proven over years", and the drill log has no restore drill in it.
Both cannot be true.

**Why it matters:** a `Completed` Velero schedule is not evidence that the data is in
the backup - a volume whose pod is not running is skipped silently, and the list only
exists in `velero backup describe --details`. Until a restore has been run against a
scratch namespace, the only untested part of this cluster is the part that brings data
back.

**What to do:** run the restore drill in
[`runbooks/drill-log.md`](runbooks/drill-log.md) (procedure: README § Drills and
cadence) and write the result into that log. The log's last row stays "not run yet"
until then.

## 6. The leaked Cilium CA key is still in the history of both remotes

**Status:** the key itself was **rotated in the cluster on 2026-10-02** - a new CA was
generated in-cluster and the agents and `hubble-relay` were restarted onto it - so the
leaked key is no longer useful. Removing it from history is
[#38](https://code.tuntelder.com/mtuntelder/nebula/issues/38), and open.

**Why it is still listed:** a key that was ever public stays compromised in every
clone, every fork and every backup of the history, including the old public GitHub
mirror (see §7). Rotation is what makes that harmless; a history purge only stops the
material from being re-derived.

**What to do:** it is a decision, not a task: purging means rewriting the history on
both hosts, force-pushing, and re-fetching every clone - and on the public mirror it
cannot be undone at all. If the decision is to purge, the order matters (rotate first,
purge second, or a rewritten history still contains a usable key). Until then, leave
the note in [`.gitleaks.toml`](../.gitleaks.toml) alone; it is the only record that a
scanner will never produce.

Background: [`runbooks/cilium-upgrades.md` § Rerolling the CA](runbooks/cilium-upgrades.md#rerolling-the-ca-a-leak-or-the-ca-near-its-own-expiry).

## 7. The GitHub copy of this repository is stale and diverged

**Status:** open, tracked as [#39](https://code.tuntelder.com/mtuntelder/nebula/issues/39).

**Looks like:** `github.com/myrenic/nebula` no longer receives the commits that land
here, and Flux reads the forge (`code.tuntelder.com/mtuntelder/nebula`), not GitHub.

**Why it matters:** a diverged mirror is worse than no mirror, because it answers the
question "what does this cluster run?" with an old answer - and it was public, which is
how the leaked CA key became a rotation instead of a deletion (§6).

**What to do:** decide, and write the decision down: either delete the mirror, or
freeze it and stop treating it as anything but an archive. Never reconcile from it and
never mirror a commit into it that was not already reviewed here.

## 8. The Prometheus volume is 97% full, and three volumes from the retired in-cluster Forgejo are detached

**Status:** open, not yet tracked as an issue.

**Looks like:**

- the Prometheus PVC holds 9.73 GiB of 10 GiB (97%); Loki is at 0.78 of 20 GiB and
  Alertmanager is effectively empty, so this is one volume, not a cluster-wide squeeze;
- `kubectl -n storage get volumes.longhorn.io` lists three detached volumes that
  belonged to the in-cluster Forgejo this repository no longer runs:
  `forgejo-postgres`, `gitea-shared-storage` and `lucian-ghost-backups`.

**Why it matters:** a full Prometheus volume does not fail loudly, it stops accepting
samples - which silently removes the monitoring the alert rules depend on. And
`reclaimPolicy: Retain` means deleting the PVC left a released PV and a Longhorn volume
behind, so the disk is allocated to nothing.

**What to do:** for the volume, either grow the PVC (Longhorn expands online) or cut
Prometheus' retention; check with `kubectl -n monitoring get pvc` and
`kubectl -n monitoring exec sts/prometheus-kube-prometheus-stack-prometheus -c prometheus -- df -h /prometheus`
before and after. For the detached volumes, confirm nothing references them - they are
attached to no workload and no PVC exists for them - then delete the Longhorn volume
and its released PV. Do not delete them on the strength of their names alone: check
`grep -r` for the PVC names in this repository first.
