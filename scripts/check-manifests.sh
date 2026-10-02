#!/usr/bin/env bash
# Check what Flux is told to apply. Run from anywhere in the repo; needs only
# kubectl, git and python3:
#
#     scripts/check-manifests.sh
#
# With RENDER_OUT set to a path, every manifest it renders is also concatenated
# there, so scripts/validate.sh can schema-check exactly the objects this walker
# walked instead of rendering a second, possibly different, set.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
fail=0
rendered_out="${RENDER_OUT:-}"
if [ -n "$rendered_out" ]; then : >"$rendered_out"; fi

# Phase 1: render every path the repo tells Flux to reconcile. Building
# kubernetes/apps and kubernetes/bootstrap only covers the ks.yaml layer, where
# a Kustomization renders as soon as it parses, so a kustomization whose
# resources point above its own root passes CI and only fails in the cluster.
echo '==> rendering Flux Kustomization paths'
kubectl kustomize kubernetes/apps >"$workdir/apps.yaml" || {
  echo 'FAIL: kubectl kustomize kubernetes/apps' >&2; exit 1; }
if [ -n "$rendered_out" ]; then
  printf -- '---\n' >>"$rendered_out"
  cat "$workdir/apps.yaml" >>"$rendered_out"
fi

python3 - "$workdir/apps.yaml" >"$workdir/paths.txt" <<'PY'
import re, sys

# python3 alone is a dependency, so the stream is read with
# indentation-anchored matching rather than a YAML library.
for doc in re.split(r'^---\s*$', open(sys.argv[1]).read(), flags=re.M):
    if not re.search(r'^kind: Kustomization$', doc, re.M):
        continue
    ref = re.search(r'^  sourceRef:\n((?:[ \t]+.*\n?)*)', doc, re.M)
    if not ref or not re.search(r'^\s+kind: GitRepository$', ref.group(1), re.M) \
            or not re.search(r'^\s+name: flux-system$', ref.group(1), re.M):
        continue
    path = re.search(r'^  path: (\S+)$', doc, re.M)
    if path:
        print(re.sub(r'^\./', '', path.group(1)))
PY

rendered=0
while IFS= read -r path; do
  if [ ! -d "$path" ]; then
    echo "FAIL: spec.path $path does not exist in this repo"; fail=1; continue
  fi
  rendered=$((rendered + 1))
  if kubectl kustomize "$path" >"$workdir/one.yaml" 2>"$workdir/err"; then
    if [ -n "$rendered_out" ]; then
      printf -- '---\n' >>"$rendered_out"
      cat "$workdir/one.yaml" >>"$rendered_out"
    fi
  else
    echo "FAIL: kubectl kustomize $path"; sed 's/^/      /' "$workdir/err"; fail=1
  fi
done <"$workdir/paths.txt"
echo "    $rendered Kustomization path(s) rendered from kubernetes/apps"

# Phase 2: orphan check. A manifest that no kustomization references is
# silently never applied and never pruned: that is how a leftover test VM
# directory survived in this repo unnoticed. A Flux Kustomization counts as a
# reference through its spec.path, which is how every .../base directory is
# reached; the surrounding kustomization.yaml only lists ks.yaml. A kustomization
# also references files through configMapGenerator.files, patches and components,
# so those count too - a walk that only followed resources: would report a file
# that is applied as ConfigMap content or as a patch as an orphan.
# A manifest that is deliberately never applied says so in its own first lines
# (`# not-applied: <reason>`); anything else is a bug.
echo '==> checking for manifests no kustomization references'
python3 - kubernetes/apps/kustomization.yaml kubernetes/bootstrap/kustomization.yaml <<'PY' || fail=1
import os, re, sys

# A marker may silence a manifest, but only in the first lines and only with a
# real reason: `# not-applied: TODO` or a one-word marker is not a decision.
NOT_APPLIED_LINES = 15
NOT_APPLIED_MIN_REASON = 20


def not_applied(path):
    """Reason from the `# not-applied:` marker at the top of a manifest, whose
    continuation is the comment lines that follow it. A placeholder reason is not
    a reason, so it does not silence the file."""
    reason, lines = [], list(open(path))[:NOT_APPLIED_LINES]
    for line in lines:
        if marker := re.search(r'# not-applied:\s*(\S.*?)\s*$', line):
            reason.append(marker.group(1))
        elif reason:
            if not line.lstrip().startswith('#'):
                break
            reason.append(line.lstrip().lstrip('#').strip())
    text = ' '.join(reason)
    if len(text) < NOT_APPLIED_MIN_REASON or re.fullmatch(r'(?i)\s*(todo|fixme|wip|n/?a|none|tbd)[.!]?\s*', text):
        return None
    return text or None


def path_entries(path):
    """Path-like entries a kustomization references: the entries of resources:
    and components:, the path: of each patches: entry, and the file names in each
    configMapGenerator's files: list. Entries that are a URL or a git ref are
    skipped - they are not files in this repository."""
    out = []
    block, in_files = None, False
    for line in open(path):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if not line[:1].isspace():
            block = stripped[:-1] if stripped.endswith(':') else None
            in_files = False
            continue
        if block in ('resources', 'components'):
            if entry := re.match(r'^-\s+(\S+)\s*$', stripped):
                out.append(entry.group(1))
        elif block == 'patches':
            if entry := re.match(r'^(?:-\s+)?path:\s*(\S+)\s*$', stripped):
                out.append(entry.group(1))
        elif block == 'configMapGenerator':
            if re.match(r'^files:\s*$', stripped):
                in_files = True
                continue
            if in_files and (entry := re.match(r'^-\s+(\S+)\s*$', stripped)):
                out.append(entry.group(1))
            else:
                in_files = False
    return [entry for entry in out
            if '://' not in entry and not entry.startswith('git@') and '?ref=' not in entry]


def refs(path):
    """Repo-relative paths that one manifest points at."""
    out = []
    if os.path.basename(path) == 'kustomization.yaml':
        base = os.path.dirname(path)
        out = [os.path.normpath(os.path.join(base, entry))
               for entry in path_entries(path)]
    for doc in re.split(r'^---\s*$', open(path).read(), flags=re.M):
        is_flux = re.search(r'^apiVersion: \S*fluxcd', doc, re.M)
        spec_path = re.search(r'^  path: (\S+)$', doc, re.M)
        if is_flux and spec_path:
            out.append(re.sub(r'^\./', '', spec_path.group(1)))
    return out

candidates = {os.path.join(root, name) for root, _, files in os.walk('kubernetes')
              for name in files if name.endswith(('.yaml', '.yml'))}
seen, queue = set(), list(sys.argv[1:])
while queue:
    item = os.path.normpath(queue.pop())
    if item in seen or not os.path.exists(item):
        continue
    seen.add(item)
    for ref in refs(item):
        if ref.endswith(('.yaml', '.yml')):
            queue.append(ref)
        else:  # a directory: its own kustomization.yaml joins the walk
            queue.append(os.path.join(ref, 'kustomization.yaml'))

skipped, orphans = [], []
for orphan in sorted(candidates - seen):
    reason = not_applied(orphan)
    if reason:
        skipped.append(f'    not applied: {orphan} ({reason})')
    else:
        orphans.append(orphan)
for line in skipped + [f'    orphan: {path}' for path in orphans]:
    print(line)
print(f'    {len(candidates) - len(orphans) - len(skipped)} referenced, '
      f'{len(orphans)} orphan(s), {len(skipped)} marked not applied')
sys.exit(1 if orphans else 0)
PY

if [ "$fail" -ne 0 ]; then
  echo 'check-manifests: FAILED'
  exit 1
fi
echo 'check-manifests: OK'
