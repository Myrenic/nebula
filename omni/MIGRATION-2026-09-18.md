# CNI-migratie Flannel -> Cilium, 18-19 september 2026

Gestart 18-09 21:22. Cluster volledig gezond op 19-09 06:30, alle drie de nodes
Ready en geen enkel faulty volume.

## Resultaat

**Cilium is de CNI en NetworkPolicy wordt gehandhaafd.** Een testpod in
`services` komt niet meer bij `mushroom-finder-postgres:5432` of bij
aiostreams. Onder Flannel kon dat wel, en daarom was deze migratie nodig.

## Wat er is gedaan

1. `omnictl cluster template sync` met patch `600-disable-flannel-cni`
   (`cluster.network.cni.name: none`) en het Cilium-manifest (CRD's + chart in
   één bestand, zie `omni/cilium/`).
2. De kube-flannel DaemonSet handmatig verwijderd; op een bestaande cluster
   haalt `cni: none` hem niet weg. Talos heeft hem niet opnieuw aangemaakt.
3. Cilium nam het over: CiliumEndpoints voor de pods, nieuwe pods krijgen een
   IP, DNS werkt.

## Wat er misging

### De NVMe-patch stond op de verkeerde plek (de echte oorzaak)

Het cluster heeft drie control-plane machines, en ze zijn niet gelijk:

| Machine | Platform | Schijven |
|---|---|---|
| `340932a1-baea-49ac-8bc0-282a554e87e6` | `nocloud` (Proxmox-VM) | 1 schijf |
| `4c4c4544-004c-4810-805a-b3c04f514433` | `metal` (Dell) | meerdere, o.a. NVMe |
| `4c4c4544-0053-5a10-8054-c7c04f333933` | `metal` (Dell) | meerdere, o.a. NVMe |

De patch `500-extra-disk-nvme0n1-longhorn` hing aan de **control-plane-set** en
werd dus ook op de VM toegepast, waar `/dev/nvme0n1` niet bestaat. De
`UserDiskConfigController` bleef daarop falen, en daardoor kon de node zijn
ephemeral-partitie en de schrijfbare overlay niet opzetten:

```
block.UserDiskConfigController: error processing user disk /dev/nvme0n1:
  lstat /dev/nvme0n1: no such file or directory
k8s.KubeletServiceController: error writing kubelet PKI:
  open /etc/kubernetes/bootstrap-kubeconfig: read-only file system
/proc/mounts: / overlay ro, lowerdir+=/layers/layer0,...     <- geen upperdir
```

Zonder schrijfbare root start kubelet niet, en dus deed de node niet meer mee.
De XFS-quotacheck-fouten op `/dev/vda5` waren een gevolg hiervan, geen
schijfschade: de schijf van de VM is nooit stuk geweest.

**Eerste diagnose was fout.** Ik dacht dat de VM zijn NVMe kwijt was en zocht
het in hardware. De tweede reboot hielp daardoor niet.

**Oplossing:** de patch van de control-plane-set naar de twee bare-metal
`Machine`-documenten verplaatst (met een eigen `idOverride` per machine). De VM
krijgt hem niet meer. Na de sync rebootte `sz9` meteen goed en kwam Ready
terug.

### Pods met een Flannel-sandbox

Pods die tijdens de overgang zijn aangemaakt, kregen een netwerksandbox van
Flannel. Toen Flannel weg was, was hun netwerk stuk:

```
plugin type="flannel" failed (add):
failed to load flannel 'subnet.env': /run/flannel/subnet.env: no such file
```

Dat trof `longhorn-csi-plugin` en `longhorn-manager`. Gevolg: de
CSI-controllers gingen naar `0/3`, de Longhorn-node werd `Ready=False` en er
konden geen volumes meer aangehangen worden, dus geen enkele pod met een volume
startte.

**Oplossing:** `longhorn-csi-plugin`, `longhorn-manager` en de vier
CSI-controller-deployments herstart, zodat ze een Cilium-sandbox kregen.
Daarnaast: pods op de onbereikbare node geforceerd verwijderd, oude
`VolumeAttachment`-objecten opgeruimd en 204 achtergebleven
`Failed`/`NodeShutdown`-pods verwijderd.

Verder waren `oauth2-proxy` (bleef hangen op OIDC-discovery) en
`helm-controller` (paniek bij het lezen van een beschadigd certificaat) stuk;
beide opgelost met een verse pod.

## Eindstand

| Onderdeel | Status |
|---|---|
| Nodes | 3 van 3 Ready |
| Cilium | actief, agents op alle nodes |
| NetworkPolicy | wordt gehandhaafd (getest) |
| Longhorn | 80 van 80 volumes gezond, 0 faulted |
| Deployments | alle gereed |
| Flux | 29 van 29 kustomizations Ready |
| aiostreams | data intact, geen verlies |

## Lessen

1. **Hang een diskpatch nooit aan een machine-set met ongelijke machines.**
   Zet hem op de `Machine`-documenten die het apparaat echt hebben. Een
   niet-bestaand device houdt de hele node uit de lucht.
2. **Na een CNI-wissel moeten pods die tijdens de overgang zijn gemaakt
   opnieuw.** Herstart expliciet de DaemonSets die de infrastructuur dragen
   (CSI, Longhorn), en de controllers die bleven hangen.
3. Op een bestaande cluster moet de Flannel DaemonSet met de hand weg; op een
   verse bootstrap met `cni: none` komt hij nooit.
4. Reken erop dat één node niet terugkomt. Met 3 nodes en 1 eruit mag je de
   tweede niet zomaar rebooten: dan verlies je quorum.
5. Doe dit niet slapend. Het is goed afgelopen, maar er waren uren waarin het
   cluster op 2 van 3 nodes draaide en niemand kon ingrijpen.
