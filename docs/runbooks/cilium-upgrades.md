# Runbook: upgrading Cilium, and the Hubble certificate lifecycle

Two things about Cilium here surprise people, and both cost an evening when they do.
The manifest the Omni template installs is applied **once**, so regenerating it does
not upgrade anything by itself. And the CA and the Hubble certificates are generated
**in the cluster**, so nothing about them is in git - which is the point, but it is
also why "where does this certificate get renewed" has no obvious answer.

## 1. `mode: one-time`: a regenerated manifest does not reach the cluster

`omni/cluster-template.yaml` refers to `cilium/cilium-install.yaml` with
`mode: one-time`. Omni applies that manifest while it configures a machine, and never
again. There is no Helm release and no Flux Kustomization for Cilium, so a cluster
that is already running does not notice a new file in this repository at all.

An upgrade is therefore four steps, and skipping the third is the trap:

```bash
cd omni/cilium
CILIUM_VERSION=1.20.3 ./generate.sh     # renders the CRDs + chart into one file
cd ../..

git diff omni/cilium                   # read it: the version header, and any CRD change

kubectl apply -f omni/cilium/cilium-install.yaml   # the RUNNING cluster

omnictl cluster template sync --file omni/cluster-template.yaml   # so a new machine gets it too
```

Then check that what runs is what the file says. The two images are the version:

```bash
kubectl -n kube-system get ds cilium -o json | python3 -c \
  'import json,sys; print([c["image"] for c in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"]])'
kubectl -n kube-system get deploy cilium-operator -o json | python3 -c \
  'import json,sys; print([c["image"] for c in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"]])'
kubectl -n kube-system exec ds/cilium -- cilium status --brief
```

(`-o json` piped into python, not `-o jsonpath`: dotted node names come back empty
from jsonpath here, which has already produced a wrong conclusion twice - see
[`talos-flux-gotchas.md`](talos-flux-gotchas.md).)

Two more things about the generated file, both deliberate:

- **The CRDs are in it.** The Cilium chart ships none, `helm show crds` returns zero
  lines, and without `CiliumNetworkPolicy` the policy layer silently does nothing.
  They are in the same file, ahead of the chart, because within one manifest the order
  is guaranteed.
- **`generate.sh` refuses to finish if a safety check fails** - a lost CRD, a missing
  `enable-host-legacy-routing` (CoreDNS stops working without it on Talos),
  `SYS_MODULE` back in the capabilities, or private key material in the render. It has
  a `--check` mode that re-runs those checks against the committed file without helm
  and without network; `scripts/validate.sh` calls it, so a regenerated file that lost
  a setting fails CI instead of the cluster.

## 2. The CA and the Hubble certificates: what regenerates what

`omni/cilium/values.yaml` sets `hubble.tls.auto.method: cronJob`. That is why the
committed manifest contains no CA and no private key: the chart renders a certificate
*generator* instead of a certificate. The default, `method: helm`, signs a CA while
`helm template` runs and writes the private key into the file that is committed - and
that is exactly how the CA and Hubble keys ended up in this repository's history.

What exists in the cluster, all in `kube-system`:

| Object | What it is | Lifetime |
| --- | --- | --- |
| Secret `cilium-ca` | the CA that signs the Hubble leaves | 3 years |
| Secret `hubble-server-certs` | the leaf `cilium-agent` serves Hubble with | 8760h (1 year) |
| Secret `hubble-relay-client-certs` | the leaf `hubble-relay` talks to the agent with | 8760h (1 year) |
| Job `hubble-generate-certs-<hash>` | one-shot run at install time | - |
| CronJob `hubble-generate-certs` | re-issues the leaves, schedule `0 0 1 */4 *` (quarterly) | - |

The generator runs with `--ca-reuse-secret`: it **reuses** an existing
`cilium-ca` and renews only the leaves. So the CA does not rotate on a schedule, and
a leak of it is not fixed by waiting for the CronJob.

Verify what is actually there, and when it expires:

```bash
kubectl -n kube-system get secret cilium-ca hubble-server-certs hubble-relay-client-certs
kubectl -n kube-system get cronjob hubble-generate-certs
kubectl -n kube-system get jobs --sort-by=.metadata.creationTimestamp | tail -5

# the dates on the material itself
for s in cilium-ca hubble-server-certs hubble-relay-client-certs; do
  echo "== $s"
  kubectl -n kube-system get secret "$s" -o json | python3 -c '
import base64, json, sys
data = json.load(sys.stdin)["data"]
pem = next(v for k, v in data.items() if k in ("ca.crt", "tls.crt"))
print(base64.b64decode(pem).decode())' | openssl x509 -noout -subject -issuer -dates
done
```

### Rerolling the CA (a leak, or the CA near its own expiry)

This was last done on **2026-10-02**, after the leaked key from the `helm` era: a new
CA was generated in-cluster and the agents and `hubble-relay` were restarted onto it.
What is left of that leak is the history purge, tracked as
[#38](https://code.tuntelder.com/mtuntelder/nebula/issues/38) - the key is dead, but
it is still readable in every clone of the past.

Rotation happens in the cluster; nothing here is edited and no secret is committed.
The leaves are re-issued by the same generator, so the CA goes first:

```bash
kubectl -n kube-system delete secret cilium-ca hubble-server-certs hubble-relay-client-certs
kubectl -n kube-system create job --from=cronjob/hubble-generate-certs hubble-generate-certs-reroll
kubectl -n kube-system wait --for=condition=complete job/hubble-generate-certs-reroll --timeout=120s
kubectl -n kube-system rollout restart ds/cilium deploy/hubble-relay
```

Then re-read the dates with the loop above: `cilium-ca` should have a fresh
`notBefore`, and both leaves should be issued by the new CA. `cilium status --wait`
(or `kubectl -n kube-system exec ds/cilium -- cilium status`) and
`kubectl -n kube-system get pods -l k8s-app=hubble-relay` confirm that the agents and
the relay came back with the new material.

The leaked keys from the `helm` era cannot be un-leaked by rotating - rotation is what
stops them being useful. They stay in the history of both hosts, including the old
public GitHub mirror, which is written down in
[`.gitleaks.toml`](../../.gitleaks.toml) because no scanner in this repository can see
into the past.
