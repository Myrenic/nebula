#!/usr/bin/env bash
# Genereert cilium-install.yaml: de CRD's plus de Cilium-chart, als één
# manifest dat de Omni-clustertemplate toepast.
#
# De uitvoer staat in git, dus een verse bootstrap heeft geen helm of netwerk
# nodig. Draai dit alleen als je Cilium wilt bijwerken:
#
#   ./generate.sh                      # versie hieronder
#   CILIUM_VERSION=1.20.3 ./generate.sh
#
# Bewust één bestand: CRD's moeten bestaan vóór de chart, en binnen één
# manifest is de volgorde gegarandeerd.
set -euo pipefail
cd "$(dirname "$0")"

CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
CRD_OWNER="cilium/cilium"
CRD_PATH="pkg/k8s/apis/cilium.io/client/crds/v2"
CRD_REF="v${CILIUM_VERSION}"
OUT="cilium-install.yaml"

command -v helm >/dev/null || { echo "helm ontbreekt" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 ontbreekt" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT

echo "== CRD's ophalen uit ${CRD_OWNER} ${CRD_REF} =="
names="$(curl -sS --fail \
  "https://api.github.com/repos/${CRD_OWNER}/contents/${CRD_PATH}?ref=${CRD_REF}" \
  | python3 -c "import sys,json;print('\n'.join(sorted(x['name'] for x in json.load(sys.stdin) if x['name'].endswith('.yaml'))))")"
for n in ${names}; do
  curl -sS --fail -o "${tmp}/${n}" \
    "https://raw.githubusercontent.com/${CRD_OWNER}/${CRD_REF}/${CRD_PATH}/${n}"
done

echo "== Cilium-chart renderen =="
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

{
  echo "# Gegenereerd door omni/cilium/generate.sh, niet met de hand aanpassen."
  echo "#"
  echo "#   cilium : ${CILIUM_VERSION}"
  echo "#   CRD's  : github.com/${CRD_OWNER} ${CRD_REF}, ${CRD_PATH}"
  echo "#   waarden: omni/cilium/values.yaml"
  echo "#"
  echo "# Eerst de CRD's, dan de chart. De Cilium Helm-chart bevat zelf geen"
  echo "# CRD's (helm show crds geeft 0 regels). Zonder deze bestanden bestaat"
  echo "# CiliumNetworkPolicy niet en doet de policy-laag stil niets."
  echo ""
  echo "# ---------------------------------------------------------------- CRD's"
  for f in "${tmp}"/*.yaml; do
    echo "---"
    cat "${f}"
  done
  echo ""
  echo "# ------------------------------------------------------------- Cilium"
  helm template cilium cilium/cilium --version "${CILIUM_VERSION}" \
    --namespace kube-system -f values.yaml
} > "${OUT}"

# Vang de twee fouten die je op Talos echt pijn doen.
crd_count="$(grep -c '^kind: CustomResourceDefinition' "${OUT}")"
[ "${crd_count}" -gt 10 ] || { echo "te weinig CRD's (${crd_count})" >&2; exit 1; }
grep -q 'ciliumnetworkpolicies' "${OUT}" || { echo "ciliumnetworkpolicies ontbreekt" >&2; exit 1; }
grep -q 'enable-host-legacy-routing: "true"' "${OUT}" || {
  echo "enable-host-legacy-routing ontbreekt; op Talos werkt DNS dan niet" >&2; exit 1; }
grep -q 'ipam: "kubernetes"' "${OUT}" || { echo "ipam staat niet op kubernetes" >&2; exit 1; }
if grep -q "SYS_MODULE" "${OUT}"; then
  echo "SYS_MODULE staat nog in de capabilities; Talos weigert dat" >&2; exit 1
fi

echo "   ${OUT}: ${crd_count} CRD's, $(wc -l < "${OUT}") regels"
echo "klaar"
