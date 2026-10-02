# Docs

Documentation for the cluster in this repo, called `talos-default` in Omni.

| Document | Question it answers |
|---|---|
| [`cluster.md`](cluster.md) | How is the cluster defined, and how do I change, validate and apply that definition? |
| [`known-issues.md`](known-issues.md) | What is broken or unexplained right now, and what is there to do about it? |
| [`incidents/2026-09-18-flannel-to-cilium.md`](incidents/2026-09-18-flannel-to-cilium.md) | How did the Flannel to Cilium migration go, and what went wrong along the way? |
| [`incidents/2026-09-19-node-reboots.md`](incidents/2026-09-19-node-reboots.md) | Why did all three nodes reboot, and what does a reboot cost the rest of the cluster? |
| [`cilium-l2-migration.md`](cilium-l2-migration.md) | Do we want to drop kube-proxy and replace MetalLB with Cilium L2, and in which order would that have to happen? |
| [`runbooks/talos-flux-gotchas.md`](runbooks/talos-flux-gotchas.md) | Which traps in `omnictl`, `talosctl`, `kubectl` and `flux` cost time here, and what works instead? |
| [`runbooks/cilium-upgrades.md`](runbooks/cilium-upgrades.md) | How do I upgrade Cilium, and what actually renews the Cilium and Hubble certificates? |
| [`runbooks/drill-log.md`](runbooks/drill-log.md) | When were the cluster's failure paths last exercised for real, and what did they teach? |
