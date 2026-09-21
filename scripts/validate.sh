#!/usr/bin/env bash
# The whole gate suite for one checkout of this repository.
#
#     scripts/validate.sh [root]        # root defaults to this repository
#
# It is called by .github/workflows/validate-changes.yaml (a push to main, or a
# human pull request) and by .github/workflows/validate-renovate.yaml, once per
# branch Renovate proposes. One definition of "checked", so a dependency bump is
# held to exactly the same rules as a hand-written change.
#
# Needs kubectl, git, python3, yamllint and kubeconform on PATH. A missing tool is a
# hard failure: a gate that silently does not run is worse than no gate.
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

fail=0
section() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

for tool in kubectl git python3 yamllint kubeconform; do
  command -v "$tool" >/dev/null || { echo "missing tool on PATH: $tool" >&2; exit 127; }
done

section 'kustomize roots'
for dir in kubernetes/apps kubernetes/bootstrap; do
  if kubectl kustomize "$dir" >/dev/null; then note "$dir renders"; else note "FAILED: $dir"; fail=1; fi
done

section 'flux paths and orphans'
scripts/check-manifests.sh || fail=1

# Every *.sops.yaml must actually be encrypted. A file named .sops.yaml without a
# sops block is a plaintext secret with a reassuring name: that is how the mytops
# TURN shared secret once ended up in a public repository.
section 'sops audit'
while IFS= read -r file; do
  grep -q '^sops:' "$file" || { note "missing sops block: $file"; fail=1; }
  grep -q 'ENC\[' "$file" || { note "no encrypted values: $file"; fail=1; }
done < <(git ls-files 'kubernetes/**/*.sops.yaml')
note "$(git ls-files 'kubernetes/**/*.sops.yaml' | wc -l) encrypted file(s) checked"

# stringData/data entries that hold a literal value instead of a ${placeholder}.
section 'plaintext secrets'
plaintext_re='^[[:space:]]+(token|password|passphrase|secret|api[-_]?key|.*_SECRET|.*_TOKEN|.*_KEY):[[:space:]]*"?[A-Za-z0-9+/=_-]{16,}'
while IFS= read -r file; do
  case "$file" in *.sops.yaml) continue ;; esac
  if grep -nE "$plaintext_re" "$file" >/dev/null; then
    note "looks like a plaintext secret: $file"
    grep -nE "$plaintext_re" "$file" | sed 's/:.*/: <redacted>/' | sed 's/^/        /'
    fail=1
  fi
done < <(git ls-files 'kubernetes/**/*.yaml')

# Exposure must be a decision, not an omission: a route is either behind an auth
# middleware or explicitly marked public with a reason. An empty glob is a failure
# of its own - it means the directory moved or the routes were deleted, which must
# not read as a pass.
section 'ingress exposure'
files=(kubernetes/apps/network/exposure/*.yaml)
if [ ! -e "${files[0]}" ]; then
  note 'FAILED: kubernetes/apps/network/exposure is missing or holds no .yaml files'
  fail=1
else
  routes=0
  for file in "${files[@]}"; do
    grep -q '^kind: IngressRoute' "$file" || continue
    routes=$((routes + 1))
    grep -qE 'oauth2-proxy-auth|lan-only|testlab\.io/exposure' "$file" && continue
    note "FAILED: $file has neither an auth middleware nor an exposure annotation"
    fail=1
  done
  note "$routes route(s) checked"
fi

section 'yaml style'
yamllint --config-file .yamllint . || fail=1

# -ignore-missing-schemas: the cluster runs CRDs from Flux, Traefik, Longhorn,
# KubeVirt, cert-manager and the Prometheus operator, which the upstream schema
# registry does not serve, and an unknown kind must not fail this gate. -strict is
# deliberately absent for the same reason.
section 'manifest schemas'
kubectl kustomize kubernetes/apps | kubeconform -ignore-missing-schemas -summary || fail=1

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "validate: FAILED ($root)" >&2
  exit 1
fi
echo "validate: OK ($root)"
