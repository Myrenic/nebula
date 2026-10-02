#!/usr/bin/env bash
# The whole gate suite for one checkout of this repository.
#
#     scripts/validate.sh [root]        # root defaults to this repository
#
# It is called by .github/workflows/validate-changes.yaml (a push to main, or a
# human pull request), by .forgejo/workflows/validate.yml (the same, on the
# canonical host) and by .github/workflows/validate-renovate.yaml, once per
# branch Renovate proposes. One definition of "checked", so a dependency bump is
# held to exactly the same rules as a hand-written change.
#
# Needs kubectl, git, python3, yamllint and kubeconform on PATH. A missing tool is a
# hard failure: a gate that silently does not run is worse than no gate.
#
# The helper script (check-manifests.sh) is always taken from the checkout this
# file lives in, never from "$root". scripts/check-renovate-branches.sh runs this
# file from the trusted revision against a renovate/* branch worktree, and a
# branch that rewrites a gate script must not thereby rewrite its own gate.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:-$(git rev-parse --show-toplevel)}"
cd "$root"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

fail=0
section() { printf '\n==> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

for tool in kubectl git python3 yamllint kubeconform; do
  command -v "$tool" >/dev/null || { echo "missing tool on PATH: $tool" >&2; exit 127; }
done

section 'kustomize roots'
for dir in kubernetes/apps kubernetes/bootstrap; do
  out="$workdir/$(basename "$dir").yaml"
  if kubectl kustomize "$dir" >"$out"; then
    note "$dir renders"
  else
    note "FAILED: $dir"
    fail=1
    : >"$out"
  fi
done

# RENDER_OUT makes check-manifests.sh hand back every render it performs, so the
# schema gate below checks exactly the objects this walker walked instead of
# rendering a second, possibly different, set.
section 'flux paths and orphans'
RENDER_OUT="$workdir/rendered.yaml" "$script_dir/check-manifests.sh" || fail=1

# Every *.sops.yaml must actually be encrypted - a file named .sops.yaml without a
# sops block is a plaintext secret with a reassuring name: that is how a plaintext
# shared secret once ended up in a public repository. The structure half parses the
# file; the decrypt half proves the age key really opens it. CI has no age key, so
# the decrypt half is conditional and says so loudly when it does not run.
section 'sops audit'
# git ls-files lists the index, so a file deleted in the working tree (an
# uncommitted `rm`) is still listed; the gates run on what is on disk.
mapfile -t sops_files < <(git ls-files 'kubernetes/**/*.sops.yaml' 'kubernetes/**/*.sops.yml' \
  | while IFS= read -r file; do if [ -e "$file" ]; then printf '%s\n' "$file"; fi; done)
if [ "${#sops_files[@]}" -eq 0 ]; then
  note 'FAILED: the *.sops.yaml/*.sops.yml glob matched no file - that is not a pass'
  fail=1
else
  python3 - "${sops_files[@]}" <<'PY' || fail=1
import re, sys

fail = 0
for path in sys.argv[1:]:
    text = open(path).read()
    if not re.search(r'^sops:', text, re.M):
        print(f'    missing sops block: {path}')
        fail = 1
        continue
    # Every value under a top-level data:/stringData:/binaryData: has to be
    # ciphertext; a literal there would be a plaintext secret wearing an
    # encrypted filename. Commented-out lines are skipped, so a comment that
    # merely says ENC[ does not make a file look encrypted.
    block, indent, encrypted = False, None, 0
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        level = len(line) - len(line.lstrip())
        if re.match(r'^(data|stringData|binaryData):\s*$', line):
            block, indent = True, level
            continue
        if not block:
            continue
        if level <= indent:
            block = False
            continue
        entry = re.match(r'^\s*([^\s:][^:]*):\s*(\S.*)$', line)
        if not entry:
            continue
        if entry.group(2).lstrip().startswith('ENC['):
            encrypted += 1
        else:
            print(f'    {path}: {entry.group(1)} is not ciphertext')
            fail = 1
    if encrypted == 0:
        print(f'    {path}: no ciphertext value under data:/stringData:/binaryData: - the filename promises encryption')
        fail = 1
sys.exit(fail)
PY

  have_key=0
  if [ -n "${SOPS_AGE_KEY:-}" ]; then have_key=1; fi
  for key_file in "${SOPS_AGE_KEY_FILE:-}" "${HOME:-/nonexistent}/.config/sops/age/keys.txt"; do
    if [ -n "$key_file" ] && [ -f "$key_file" ]; then have_key=1; fi
  done
  if [ "$have_key" -eq 1 ]; then
    for file in "${sops_files[@]}"; do
      sops -d "$file" >/dev/null || { note "FAILED: sops cannot decrypt $file"; fail=1; }
    done
    note "${#sops_files[@]} encrypted file(s) decrypted and structure-checked"
  else
    note "WARNING: no age key (SOPS_AGE_KEY, SOPS_AGE_KEY_FILE or ~/.config/sops/age/keys.txt),"
    note "         so DECRYPTION WAS SKIPPED for ${#sops_files[@]} file(s); only their structure was"
    note "         checked. Run this on the machine that holds the key before trusting the audit."
  fi
fi

# stringData/data entries that hold a literal value instead of a ${placeholder}.
# The value is only ever printed redacted - a gate that echoes the secret it found
# puts the secret in the CI log.
section 'plaintext secrets'
{ git ls-files '*.yaml' '*.yml' '*.json' || true; } | grep -vE '\.sops\.ya?ml$' >"$workdir/tracked.txt" || true
while IFS= read -r file; do if [ -e "$file" ]; then printf '%s\n' "$file"; fi; done \
  <"$workdir/tracked.txt" >"$workdir/scan.txt"
python3 - "$workdir/scan.txt" <<'PY' || fail=1
import re, sys

# Keys whose *value* is a credential. Secret names and references are excluded on
# purpose: secretName, secretRef, existingSecret and apiTokenSecretRef name a
# Secret, they do not hold one, and matching them flags ordinary configuration.
# A bare `-key` suffix is not in the generic rule either: keys like
# `agent-not-ready-taint-key` and `node-selector-key` hold identifiers, so the
# credential-shaped `*_key` names are listed one by one.
HOLDS_A_SECRET = re.compile(r'''(?ix)^(
      token|password|passwd|passphrase|secret|apikey|bearer
    | api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key
    | encryption[_-]?key|signing[_-]?key|client[_-]?key
    | client[_-]?secret|credential|credentials
    | bearer[_-]?token|auth[_-]?token
    | [a-z0-9]+([_-][a-z0-9]+)*[_-](secret|token|password|passwd|passphrase|credential)s?
)$''')
# Template placeholders and shell/CI references this repo uses legitimately:
# ${SECRET_DOMAIN_0}, $(cat file), ${{ secrets.X }} and {FRIGATE_MQTT_PASSWORD}.
PLACEHOLDER = re.compile(r'\$\{|\$\(|\{\{|<[A-Za-z_-]+>|\{[A-Za-z0-9_.-]+\}')
ENTRY = re.compile(r'^(\s*)([A-Za-z0-9_.-]+):\s*(.*)$')
MIN_LENGTH = 16

fail = 0
for path in open(sys.argv[1]).read().split():
    for number, line in enumerate(open(path, errors='replace'), 1):
        if line.lstrip().startswith('#'):
            continue
        entry = ENTRY.match(line.rstrip('\n'))
        if not entry or not HOLDS_A_SECRET.match(entry.group(2)):
            continue
        value = re.split(r'\s+#', entry.group(3))[0].strip().strip('"\'')
        if not value or PLACEHOLDER.search(value):
            continue
        if len(value) >= MIN_LENGTH:
            print(f'    {path}:{number}: {entry.group(2)} holds {len(value)} literal characters')
            fail = 1
sys.exit(fail)
PY

# Exposure must be a decision, not an omission: every route of every IngressRoute
# is either behind an auth middleware from the allowlist or covered by an explicit
# `testlab.io/exposure` annotation with a value from its own allowlist, and every
# route terminates TLS. This parses the rendered manifests - a comment that
# mentions oauth2-proxy, or `testlab.io/exposure: false`, must not read as a pass.
# An empty render is a failure of its own: it means the directory moved or the
# routes were deleted, which must not read as "nothing to check".
section 'ingress exposure'
if ! kubectl kustomize kubernetes/apps/network/exposure >"$workdir/exposure.yaml"; then
  note 'FAILED: kubernetes/apps/network/exposure does not render'
  fail=1
else
  python3 - "$workdir/exposure.yaml" <<'PY' || fail=1
import re, sys

AUTH_MIDDLEWARES = {'oauth2-proxy-auth', 'lan-only'}
EXPOSURE_VALUES = {'public'}

def indent(line):
    return len(line) - len(line.lstrip())


fail = 0
routes = 0
for doc in re.split(r'^---\s*$', open(sys.argv[1]).read(), flags=re.M):
    if not re.search(r'^kind: IngressRoute$', doc, re.M):
        continue
    found_name = re.search(r'^  name: (\S+)$', doc, re.M)
    name = found_name.group(1) if found_name else '(unnamed)'
    annotation = re.search(r'^\s*testlab\.io/exposure:\s*(\S+)\s*$', doc, re.M)
    exposure = annotation.group(1).strip('"\'') if annotation else None
    if not re.search(r'^  tls:', doc, re.M):
        print(f'    FAILED: {name} has no spec.tls')
        fail = 1

    lines = doc.splitlines()
    for index, line in enumerate(lines):
        if not re.match(r'^(\s*)routes:\s*$', line):
            continue
        # The block sequence sits at the key's own indentation: kustomize writes
        # `routes:` and its `- kind: Rule` items in the same column, so the body
        # ends at the next key in that column (`tls:`).
        key_indent = indent(line)
        body = []
        for following in lines[index + 1:]:
            if not following.strip():
                body.append(following)
                continue
            level = indent(following)
            if level < key_indent:
                break
            if level == key_indent and not following.lstrip().startswith('- '):
                break
            body.append(following)

        starts = [i for i, entry in enumerate(body)
                  if indent(entry) == key_indent and entry.lstrip().startswith('- ')]
        for begin, end in zip(starts, starts[1:] + [len(body)]):
            middlewares = []
            collecting = None
            for inner in body[begin:end]:
                level = indent(inner)
                if collecting is None:
                    if re.match(r'^\s*middlewares:\s*$', inner):
                        collecting = level
                elif level == collecting and inner.lstrip().startswith('- '):
                    found = re.match(r'^\s*-\s*name:\s*(\S+)', inner)
                    if found:
                        middlewares.append(found.group(1))
                elif inner.strip() and level <= collecting:
                    collecting = None
            routes += 1
            if not (set(middlewares) & AUTH_MIDDLEWARES) and exposure not in EXPOSURE_VALUES:
                if exposure is None:
                    print(f'    FAILED: {name} route has no auth middleware and no exposure annotation')
                else:
                    print(f'    FAILED: {name} exposure "{exposure}" is not one of {sorted(EXPOSURE_VALUES)} '
                          'and the route has no auth middleware')
                fail = 1

if routes == 0:
    print('    FAILED: kubernetes/apps/network/exposure rendered zero IngressRoute routes')
    sys.exit(1)
print(f'    {routes} route(s) checked')
sys.exit(fail)
PY
fi

section 'yaml style'
yamllint --config-file .yamllint . || fail=1

# Versions that have to move together, because the repo was bitten by them not
# moving together: the vendored Traefik CRD bundle was 3.1 while the binary ran
# 3.7, and its newer fields were silently pruned. Minor/major disagreement fails;
# a patch-level skew is reported but tolerated deliberately - the bundle is
# re-downloaded only when a field changes, and failing on every upstream patch
# would turn a byte-identical file into a commit for each patch release.
section 'version drift'
traefik_crds=kubernetes/apps/network/traefik-crds/crds.yaml
traefik_image=kubernetes/apps/network/traefik/base/deployment.yaml
crd_version="$(grep -m1 -oE 'traefik/traefik/v[0-9]+\.[0-9]+\.[0-9]+/docs/' "$traefik_crds" 2>/dev/null | sed -E 's|.*/v([0-9.]+)/docs/|\1|' || true)"
image_version="$(grep -m1 -oE 'image: traefik:v[0-9]+\.[0-9]+\.[0-9]+' "$traefik_image" 2>/dev/null | sed -E 's|.*:v||' || true)"
if [ -z "$crd_version" ] || [ -z "$image_version" ]; then
  note "FAILED: cannot read the Traefik CRD version ('$crd_version') or image version ('$image_version')"
  fail=1
elif [ "${crd_version%.*}" != "${image_version%.*}" ]; then
  note "FAILED: Traefik CRDs v$crd_version vs image v$image_version - the CRD bundle must be"
  note "        re-vendored from the image's release (kubernetes/apps/network/traefik-crds/crds.yaml)"
  fail=1
elif [ "$crd_version" != "$image_version" ]; then
  note "WARNING: Traefik CRDs v$crd_version vs image v$image_version - same minor, patch skew"
  note "         that the next CRD re-vendor should close"
else
  note "Traefik CRDs and image agree on v$image_version"
fi

# The generated Cilium manifest is not regenerated by anything: it is applied as a
# mode: one-time manifest from the Omni template, so a version that only reaches
# generate.sh's default never reaches the cluster. Its own `--check` is the
# coherence test - the header's Cilium version against CILIUM_VERSION, the CRD
# count, and that no key material is in the render - and it needs no network, no
# helm and no age key.
cilium_generator=omni/cilium/generate.sh
if cilium_check="$(bash "$cilium_generator" --check 2>&1)"; then
  note "$cilium_check"
else
  note "FAILED: $cilium_generator --check"
  printf '%s\n' "$cilium_check" | sed 's/^/        /'
  fail=1
fi

# -strict, so a field the API server would reject is a failure here rather than a
# pruned field in the cluster, and every schema the registry does not serve fails
# the gate instead of being waved through. The CRD groups this cluster runs (Flux,
# Traefik, cert-manager, the Prometheus operator, MetalLB, Velero, Longhorn) come
# from the datreeio/CRDs-catalog, pinned to the commit below: bump it in the same
# commit that adopts a new CRD version, and refresh it with
#   curl -sS https://api.github.com/repos/datreeio/CRDs-catalog/commits/main | python3 -c 'import json,sys;print(json.load(sys.stdin)["sha"])'
# CustomResourceDefinition is skipped explicitly, not silently: no schema exists
# for apiextensions.k8s.io/v1 (neither the upstream registry nor the catalog
# carries it), and those ten objects are the vendored Traefik bundle the drift
# gate above already pins. The summary prints how many were skipped.
#
# The `sops:` block an encrypted Secret carries is stripped first: it is not part
# of the Secret schema, and Flux removes it while decrypting, before the object
# reaches the API server - so what is validated here is what is applied.
section 'manifest schemas'
crd_catalog_commit=d373c2da9702bc9509a004db83e57263fe3bdfc1
# FNR==1 && NR!=1 inserts a document separator between the two files as well as
# inside them: kustomize does not end a render with one, so without it the last
# document of the first file and the first document of the second merge into one
# object with duplicate keys.
awk 'FNR==1 && NR!=1 {print "---"}
     /^sops:/{skip=1;next}
     skip && /^[^[:space:]#]/{skip=0}
     skip{next}
     {print}' \
    "$workdir/rendered.yaml" "$workdir/bootstrap.yaml" \
  | kubeconform -strict -summary -skip CustomResourceDefinition \
      -schema-location default \
      -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$crd_catalog_commit/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
      - || fail=1

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "validate: FAILED ($root)" >&2
  exit 1
fi
echo "validate: OK ($root)"
