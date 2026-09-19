# Omni-clusterdefinitie

Dit is de bron van waarheid voor cluster `talos-default`: de clustertemplate
die Omni toepast, plus de Cilium-manifesten die daarbij horen.

Omni zet de machineconfig van de nodes terug naar wat in de template staat.
Wijzig dus nooit iets rechtstreeks met `talosctl` op een node: het wordt
teruggedraaid. Alles hoort hier.

## Bestanden

| Bestand | Wat |
|---|---|
| `cluster-template.yaml` | De clustertemplate: machines, patches en de Cilium-manifestreferentie |
| `cilium/values.yaml` | Helm-waarden voor Cilium (de bron) |
| `cilium/generate.sh` | Genereert `cilium-install.yaml` uit die waarden + de CRD's |
| `cilium/cilium-install.yaml` | Gegenereerd. CRD's plus de Cilium-chart in één bestand |

## Toepassen

De paden in de template zijn **relatief aan de template zelf**, niet aan je
werkmap. Draai dus vanuit de root van de repo:

```bash
export OMNI_ENDPOINT=https://omni.tuntelder.com/
export OMNI_SERVICE_ACCOUNT_KEY=...        # service account key

omnictl cluster template validate --file omni/cluster-template.yaml
omnictl cluster template render   --file omni/cluster-template.yaml >/dev/null
omnictl cluster template diff     --file omni/cluster-template.yaml
omnictl cluster template sync     --file omni/cluster-template.yaml
```

Let op: `validate` controleert **niet** of de manifestbestanden bestaan. Alleen
`render` doet dat. Slaagt `render`, dan klopt het pad.

**Een wijziging aan de machineconfig laat alle nodes rebooten.** Reken op
5-15 minuten waarin het cluster helemaal weg is, inclusief de VM's.

### Bestaande cluster omzetten (niet alleen bootstrap)

Bij een verse bootstrap met `cni: none` komt Flannel nooit. Op een bestaand
cluster blijft de DaemonSet staan en moet je hem zelf weghalen, anders draaien
er twee CNI's naast elkaar:

```bash
kubectl -n kube-system delete ds kube-flannel
```

Daarna moeten pods die tijdens de overgang zijn gemaakt opnieuw, want hun
netwerksandbox is nog van Flannel:

```bash
kubectl -n storage rollout restart ds longhorn-csi-plugin
kubectl -n storage rollout restart ds longhorn-manager
kubectl -n storage rollout restart deploy csi-attacher csi-provisioner csi-resizer csi-snapshotter
```

Zonder die stap blijven de CSI-controllers op `0/3`, wordt de Longhorn-node
`Ready=False` en start geen enkele pod met een volume. De volledige nasleep
staat in `MIGRATION-2026-09-18.md`.

## Cilium

Cilium is de CNI; Flannel staat uit via patch `600-disable-flannel-cni`.
Cilium wordt als `mode: one-time` manifest neergezet: Omni installeert het bij
de bootstrap, daarna beheert Cilium zichzelf. Een upgrade is een bewuste
handeling (`./generate.sh` met een nieuwe versie, daarna syncen).

### CRD's zitten er bewust bij

De Cilium Helm-chart bevat **geen CRD's**. `helm show crds cilium/cilium`
geeft nul regels en de chart heeft geen `crds/`-map; hij heeft wel een
`crdWaitTimeout` en wacht tot ze bestaan. Zonder CRD's bestaat
`CiliumNetworkPolicy` niet en doet de policy-laag **stil niets** — precies de
situatie waar we uit kwamen met Flannel. Daarom staan de CRD's in
`cilium-install.yaml`, vóór de chart (binnen één bestand is de volgorde
gegarandeerd).

### Talos-specifieke instellingen

| Instelling | Waarom |
|---|---|
| `ipam.mode=kubernetes` | hergebruikt de podCIDR per node die er al is |
| `kubeProxyReplacement=false` | kube-proxy blijft service-routing doen; kleinere stap |
| `bpf.hostLegacyRouting=true` | **verplicht**: Talos stuurt kube-dns door naar de host-DNS, dat botst met Cilium's eBPF host-routing, en zonder dit werkt CoreDNS niet |
| capabilities zonder `SYS_MODULE` | Talos staat workloads niet toe kernelmodules te laden |
| `cgroup.autoMount.enabled=false` | Talos mount cgroupv2 en bpffs al |

`generate.sh` controleert na het genereren op `enable-host-legacy-routing`,
`ipam: kubernetes`, de aanwezigheid van `ciliumnetworkpolicies` en de
afwezigheid van `SYS_MODULE`. Faalt een van die checks, dan stopt het script.

### Bijwerken

```bash
cd omni/cilium
CILIUM_VERSION=1.20.3 ./generate.sh
cd ../..
git diff omni/cilium                    # bekijk wat er verandert
omnictl cluster template sync --file omni/cluster-template.yaml
```

## Machines zijn niet gelijk

De control-plane bestaat uit twee bare-metal Dells en één Proxmox-VM
(`talos.platform=nocloud`). Alleen de Dells hebben `/dev/nvme0n1`.

Machine-specifieke hardware hoort daarom in een **`Machine`-document**, niet op
de `ControlPlane`-set. De NVMe-Longhorn-patch stond eerst set-breed, werd ook
op de VM toegepast, en hield die node uit de lucht: de falende
`UserDiskConfigController` verhinderde de schrijfbare overlay, waarna kubelet
niet meer startte. Zie `MIGRATION-2026-09-18.md`.

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

Twee machines kunnen niet dezelfde `idOverride` hebben; geef elke machine een
eigen ID.

## Netwerkbeleid

NetworkPolicy's deden niets onder Flannel. Met Cilium worden ze actief,
inclusief de vier die met Flux meekomen (`flux-system/allow-*`) en de drie van
de paddenstoelenapp.

Rol nieuwe policies gefaseerd uit: eerst Cilium in audit-mode, dan kijken met
Hubble wat er weg zou vallen, dan pas handhaven.

## Controleren

```bash
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=cilium
cilium status --wait
cilium connectivity test
omnictl get clusterkubernetesmanifestsstatuses talos-default
```

## Terugdraaien

1. Patch `600-disable-flannel-cni` uit `cluster-template.yaml` halen.
2. `omnictl cluster template sync --file omni/cluster-template.yaml`
3. Nodes rebooten; Flannel komt terug.
4. Cilium opruimen kan daarna met `cilium uninstall`.

Velero was tijdens de overstap niet beschikbaar (backupstoragelocation
`Unavailable`), dus er is geen extra snapshot gemaakt. Een reboot verwijdert
geen Longhorn-volumes, maar het is goed te weten dat dat vangnet er niet was.
