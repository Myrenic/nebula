# Cilium L2 plan: drop kube-proxy, replace MetalLB

**Nothing of this network plan has been applied.** No Cilium change, no MetalLB
change.

## Blocking order

This is one path, not two separate wishes: L2 announcements require
`kubeProxyReplacement=true` (this is in the Cilium L2 docs), so the steps have to
happen in this order.

1. `kubeProxyReplacement=true` + `k8sServiceHost/k8sServicePort` (Talos KubePrism
   `localhost:7445`), and Talos `cluster.proxy.disabled: true`
   -> **rolling reboot of all nodes**.
2. `l2announcements.enabled=true` + `CiliumL2AnnouncementPolicy` +
   `CiliumLoadBalancerIPPool` for `10.0.50.4-10.0.50.6`.
3. Only then remove MetalLB (runs in namespace `network`, pool `pool`; the only LB
   service is `network/traefik` on `10.0.50.4`).

## The honest story about the gain

On 3 nodes the performance gain of removing kube-proxy is **zero** — not
measurable. The real reasons are: one component less, it is a *precondition* for
L2 (and therefore for removing MetalLB), and access to Cilium-only LB features
(DSR, Maglev, BGP). Risk: get it wrong and there is no service routing cluster-wide.

## Two concrete gotchas in the existing manifests

- The `network/traefik` Service uses `externalTrafficPolicy: Local`. Cilium L2
  wants **`Cluster`** (otherwise the VIP is announced on nodes without a Traefik
  pod -> drops).
- The IP pin is now `metallb.io/loadBalancerIPs: 10.0.50.4`; that becomes Cilium's
  `io.cilium/lb-ipam-ips`.

Recommendation: a separate maintenance window, not combined — and certainly not
straight after today's reboots.
