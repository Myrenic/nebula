#!/usr/bin/env bash
# Check what Flux is told to apply. Run from anywhere in the repo; needs only
# kubectl, git and python3:
#
#     scripts/check-manifests.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
fail=0

# Phase 1: render every path the repo tells Flux to reconcile. Building
# kubernetes/apps and kubernetes/bootstrap only covers the ks.yaml layer, where
# a Kustomization renders as soon as it parses, so a kustomization whose
# resources point above its own root passes CI and only fails in the cluster.
echo '==> rendering Flux Kustomization paths'
kubectl kustomize kubernetes/apps >"$workdir/apps.yaml" || {
  echo 'FAIL: kubectl kustomize kubernetes/apps' >&2; exit 1; }

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
  if ! kubectl kustomize "$path" >/dev/null 2>"$workdir/err"; then
    echo "FAIL: kubectl kustomize $path"; sed 's/^/      /' "$workdir/err"; fail=1
  fi
done <"$workdir/paths.txt"
echo "    $rendered Kustomization path(s) rendered from kubernetes/apps"

# Phase 2: orphan check. A manifest that no kustomization references is
# silently never applied and never pruned: that is how a leftover test VM
# directory survived in this repo unnoticed. A Flux Kustomization counts as a
# reference through its spec.path, which is how every .../base directory is
# reached; the surrounding kustomization.yaml only lists ks.yaml.
# A manifest that is deliberately never applied says so in its own first lines
# (`# not-applied: <reason>`); anything else is a bug.
echo '==> checking for manifests no kustomization references'
python3 - kubernetes/apps/kustomization.yaml kubernetes/bootstrap/kustomization.yaml <<'PY' || fail=1
import os, re, sys


def not_applied(path):
    """Reason from the `# not-applied:` marker at the top of a manifest, whose
    continuation is the comment lines that follow it."""
    reason, lines = [], list(open(path))[:15]
    for line in lines:
        if marker := re.search(r'# not-applied:\s*(\S.*?)\s*$', line):
            reason.append(marker.group(1))
        elif reason:
            if not line.lstrip().startswith('#'):
                break
            reason.append(line.lstrip().lstrip('#').strip())
    return ' '.join(reason) or None


def resources(path):
    """Entries of the top-level `resources:` list of a kustomization."""
    entries, inside = [], False
    for line in open(path):
        if re.match(r'^resources:', line):
            inside = True
        elif inside and (item := re.match(r'^[ \t]*-[ \t]+(\S+)\s*$', line)):
            entries.append(item.group(1))
        elif inside and line.strip() and not line.lstrip().startswith('#'):
            inside = False
    return entries


def refs(path):
    """Repo-relative paths that one manifest points at."""
    out = []
    if os.path.basename(path) == 'kustomization.yaml':
        base = os.path.dirname(path)
        out = [os.path.normpath(os.path.join(base, entry))
               for entry in resources(path) if '://' not in entry
               and not entry.startswith('git@') and '?ref=' not in entry]
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
