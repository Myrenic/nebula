# Drill log

One line per time the cluster's failure paths were actually exercised - a planned
drill, or an incident that turned into one. The point is not ceremony: the two
entries below are both incidents, and what they taught is the part that had to
survive. A path that has never been walked is not known to work.

| Date | Commit | Exercised | Learned | Broke |
| --- | --- | --- | --- | --- |
| 2026-09-18 | not recorded - which is its own lesson | Live CNI switch, Flannel to Cilium: `cni: none` in the template, Cilium manifest applied, the Flannel DaemonSet deleted by hand | A per-disk patch on a machine *set* hits the machines that do not have the disk; pods that got their sandbox from the old CNI do not follow the new one (restart the CSI and Longhorn DaemonSets); with 3 nodes, after losing one there is no quorum left to reboot a second | `talos-sz9-1vs` down for hours on a `/dev/nvme0n1` it does not have (`UserDiskConfigController`), Longhorn CSI at `0/3` and no volume attachable, 204 leftover Failed/NodeShutdown pods |
| 2026-09-19 | `847f75d` | Traefik rollout with probes and `maxUnavailable: 0`, and then all three nodes rebooting inside the hour with no upgrade behind it | A `ReadWriteMany` Longhorn volume that nothing mounts is still a reboot-hang risk (deleted with its PV); a reboot costs that node's Longhorn instance-manager but recovers unattended; Talos keeps no logs of the previous boot, so an unexplained reboot has to be captured while it is happening | 98 dead pod objects; `frigate-media` came back faulted and `autoSalvage` rebuilt the engine from the on-disk replica |
| not run yet | - | Velero restore of a real volume into a scratch namespace, from the schedule's own backup | Every other entry here is a lesson; this one is still a promise - `Completed` on a Velero schedule is not proof that the data is in the backup, because a volume is skipped silently when its pod is not running | - |

**The restore row is not run yet**, and that is tracked as
[#37](https://code.tuntelder.com/mtuntelder/nebula/issues/37) - the introduction to
this repository calls the restore path "drilled", which is what the log is here to
disagree with. The procedure to run is README § Drills and cadence; the result belongs
in that row, replacing "not run yet".

Details for the first two: [`incidents/2026-09-18-flannel-to-cilium.md`](../incidents/2026-09-18-flannel-to-cilium.md)
and [`incidents/2026-09-19-node-reboots.md`](../incidents/2026-09-19-node-reboots.md).
The Velero traps that the last row is meant to close are in
[`talos-flux-gotchas.md`](talos-flux-gotchas.md), and the open items the log keeps
pointing at are in [`../known-issues.md`](../known-issues.md).

The `Commit` column is the revision the drill ran at. Leave it empty rather than
guessing: "not recorded" is a reminder to note it next time, and it is why the first
row cannot be re-read against a tree.
