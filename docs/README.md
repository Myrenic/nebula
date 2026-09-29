# Docs

Documentation for the cluster in this repo, called `talos-default` in Omni.

| Document | Question it answers |
|---|---|
| [`cluster.md`](cluster.md) | How is the cluster defined, and how do I change, validate and apply that definition? |
| [`incidents/2026-09-18-flannel-to-cilium.md`](incidents/2026-09-18-flannel-to-cilium.md) | How did the Flannel to Cilium migration go, and what went wrong along the way? |
| [`incidents/2026-09-19-node-reboots.md`](incidents/2026-09-19-node-reboots.md) | Why did all three nodes reboot, and what does a reboot cost the rest of the cluster? |
| [`cilium-l2-migration.md`](cilium-l2-migration.md) | Do we want to drop kube-proxy and replace MetalLB with Cilium L2, and in which order would that have to happen? |
| [`runbooks/talos-flux-gotchas.md`](runbooks/talos-flux-gotchas.md) | Which traps in `omnictl`, `talosctl`, `kubectl` and `flux` cost time here, and what works instead? |
