# CNI-migratie Flannel -> Cilium, 18 september 2026

Gestart 21:22, cluster draaide om 22:30 weer op twee nodes.

## Wat er is gedaan

1. `omnictl cluster template sync` met de nieuwe template: patch
   `600-disable-flannel-cni` (`cluster.network.cni.name: none`) en het
   manifest `cilium` (CRD's + chart in één bestand).
2. De kube-flannel DaemonSet was daarna nog aanwezig (op een bestaande
   cluster haalt `cni: none` hem niet weg) en is met de hand verwijderd.
   Talos heeft hem niet opnieuw aangemaakt, dus de patch werkt.
3. Cilium nam het over: 70 CiliumEndpoints, nieuwe pods krijgen een IP,
   DNS werkt.

**Resultaat: NetworkPolicy wordt nu gehandhaafd.** Een testpod in `services`
komt niet meer bij `mushroom-finder-postgres:5432` of bij aiostreams. Onder
Flannel kon dat wel; daarom was deze migratie nodig.

## Wat er misging

### Eén node kwam niet terug (hardware)

`talos-sz9-1vs` rebootte als onderdeel van de configuratiewijziging en kwam
terug zonder zijn extra NVMe-schijf:

```
block.UserDiskConfigController: error processing user disk /dev/nvme0n1:
  lstat /dev/nvme0n1: no such file or directory
k8s.KubeletServiceController: error writing kubelet PKI:
  open /etc/kubernetes/bootstrap-kubeconfig: read-only file system
```

De schijf wordt door de kernel niet meer gezien, de root van die node staat
daardoor read-only en kubelet start niet. Een tweede reboot hielp niet. Dit is
hardware: de schijf of de aansluiting moet fysiek nagekeken worden.

Deze node had al een geschiedenis van control-plane churn, zie `plan.md` en
`chacdn-findings.md`.

### Pods met een Flannel-sandbox

Pods die tijdens de overgang zijn aangemaakt, kregen een netwerksandbox van
Flannel. Toen Flannel weg was, was hun netwerk stuk:

```
plugin type="flannel" failed (add):
failed to load flannel 'subnet.env' file: /run/flannel/subnet.env: no such file
```

Dat trof `longhorn-csi-plugin` en `longhorn-manager`. Gevolg op een rij:

- CSI-controllers (`csi-attacher`, `csi-provisioner`, `csi-resizer`,
  `csi-snapshotter`) gingen naar `0/3`.
- Longhorn-node `talos-45w-c87` werd `Ready=False` en de instance-manager daar
  verdween, dus Longhorn weigerde volumes te attachen:
  `node talos-45w-c87 is not ready, couldn't attach volume`.
- Daardoor startten alle pods met een volume niet.

### Opgelost met

- Pods op de onbereikbare node geforceerd verwijderd (containers waren daar al
  dood, dus geen dubbele schrijver).
- Oude `VolumeAttachment`-objecten naar de dode node verwijderd.
- `longhorn-csi-plugin`, `longhorn-manager` en de vier CSI-controller-
  deployments herstart, zodat ze een Cilium-sandbox kregen. Daarna gingen de
  CSI-controllers naar `3/3` en kwam de Longhorn-node weer op `Ready`.
- 204 achtergebleven `Failed`/`NodeShutdown`-pods opgeruimd (kubelet-resten van
  alle reboots, eigendom van ReplicaSets die dachten dat ze klaar waren).
- `oauth2-proxy` herstart; die was tijdens de herstart van Keycloak blijven
  hangen op OIDC-discovery (kreeg HTML in plaats van JSON).

## Eindstand

| Onderdeel | Status |
|---|---|
| Nodes | 2 van 3 Ready; `talos-sz9-1vs` NotReady (schijf kwijt) |
| Cilium | actief op beide gezonde nodes, 2/2 agents |
| NetworkPolicy | **wordt gehandhaafd** (getest) |
| Longhorn | 79 van 80 volumes gezond |
| Deployments | alles gereed behalve `aiostreams` |
| Paddenstoelen-app | werkt |

## Wat jij moet doen

1. **`talos-sz9-1vs` fysiek nakijken.** De NVMe wordt niet gedetecteerd. Zonder
   die schijf komt de node niet terug. Staat hij er weer in, dan herstelt
   Longhorn de replica's vanzelf.
2. **aiostreams.** Het volume `pvc-f0c5ca6c` had één replica, op de verdwenen
   schijf. Longhorn zegt `not ready for workloads`. Komt de schijf terug, dan
   is het er weer; anders moet het volume opnieuw opgebouwd worden en ben je de
   data kwijt. Dat is een keuze, geen automatisme.
3. **Velero is stuk** (pre-existent): `backupstoragelocation/default` staat al
   19 dagen op `Unavailable` en `velero-ui` crashloopt. Er is dus geen
   vangnet. Dit is de moeite waard om als volgende op te pakken.

## Lessen voor de volgende keer

- Migreer de CNI niet op een cluster waar nog een langdurige klus loopt, en
  zeker niet zonder werkende backups.
- Na de overstap moeten pods die tijdens de overgang zijn gemaakt opnieuw:
  herstart de DaemonSets die de infrastructuur dragen (CSI, Longhorn) expliciet.
- Op een bestaande cluster moet de Flannel DaemonSet met de hand weg; op een
  verse bootstrap met `cni: none` komt hij nooit.
- Reken erop dat één node niet terugkomt. Zorg dat er quorum overblijft: met 3
  nodes en 1 eruit mag je de tweede niet zomaar rebooten.
