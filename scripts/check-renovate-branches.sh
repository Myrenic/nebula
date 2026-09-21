#!/usr/bin/env bash
# Validate the branches Renovate proposes, with the same gate suite as any other
# change: scripts/validate.sh, in a throwaway worktree per branch.
#
#     scripts/check-renovate-branches.sh [--out results.tsv] [--list] [--remote origin]
#
#   --out FILE   write one line per branch: <branch>\t<sha>\tPASS|FAIL\t<detail>
#   --list       only print "<branch>\t<sha>" for every branch (used to post a
#                pending status before validation, so a failure to report cannot be
#                mistaken for a pass)
#
# Why this exists: a pull_request event raised by a PR that GITHUB_TOKEN opened is
# held as `action_required`, so the normal CI needs a human to approve each run of
# every dependency PR. This walks the branches instead, in a workflow that runs in
# the repository's own context and needs no approval.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
out=""
list_only=0
remote=origin
base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="${2:?--out needs a path}"; shift 2 ;;
    --list) list_only=1; shift ;;
    --remote) remote="${2:?--remote needs a name}"; shift 2 ;;
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

branches() {
  git for-each-ref --format='%(refname:short)' "refs/remotes/$remote/renovate/*" \
    | sed "s|^$remote/||" | sort
}

git fetch --quiet --prune "$remote" \
  "+refs/heads/renovate/*:refs/remotes/$remote/renovate/*" \
  "+refs/heads/main:refs/remotes/$remote/main" || true

# Default to the base branch as this checkout sees it; --base overrides it (useful
# to check pending branches against an unpushed local branch).
base="${base:-$remote/main}"
git rev-parse --verify --quiet "$base" >/dev/null || {
  echo "base ref not found: $base" >&2; exit 2; }
# Resolve it here, in the main checkout: inside a branch worktree, HEAD and even a
# branch name would resolve against that worktree, and --base HEAD would silently
# merge the branch into itself.
base_sha="$(git rev-parse "$base")"

if [ "$list_only" -eq 1 ]; then
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    printf '%s\t%s\n' "$branch" "$(git rev-parse "$remote/$branch")"
  done < <(branches)
  exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
results="$workdir/results.tsv"
: >"$results"

while IFS= read -r branch; do
  [ -n "$branch" ] || continue
  ref="$remote/$branch"
  sha="$(git rev-parse "$ref")"
  wt="$workdir/$sha"
  log="$workdir/$sha.log"

  printf '==> %s (%s)\n' "$branch" "${sha:0:8}"
  state=FAIL
  detail="could not create a worktree for this branch"
  if git worktree add --quiet --detach "$wt" "$ref" 2>/dev/null; then
    # What matters is the tree that would land on main, not the branch in
    # isolation: a branch cut two days ago fails gates that main has since
    # outgrown, and a bump that no longer applies on top of main is exactly the
    # case a reviewer needs to see. So merge main in first, then validate that.
    if ! git -C "$wt" -c user.name=renovate-validate -c user.email=renovate-validate@localhost \
        merge --no-edit --quiet "$base_sha" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      state=FAIL
      detail="does not merge cleanly into ${base#*/}"
    # Run the base checkout's script against the merged tree: the gates come from
    # the trusted revision, the manifests from the branch under test.
    elif bash "$PWD/scripts/validate.sh" "$wt" >"$log" 2>&1; then
      state=PASS
      detail="merges into ${base##*/} and passes every gate"
    else
      detail="$(grep -m1 -E 'FAILED|not in or below|error:|Error:|is missing' "$log" | tr -s ' ' | cut -c1-120)"
      [ -n "$detail" ] || detail="a gate failed (see the run log)"
      sed 's/^/    /' "$log" | tail -20
    fi
    git worktree remove --force "$wt" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\n' "$branch" "$sha" "$state" "$detail" | tee -a "$results"
done < <(branches)

if [ -n "$out" ]; then
  cp "$results" "$out"
fi

passed="$(awk -F'\t' '$3=="PASS"' "$results" | wc -l)"
total="$(grep -c . "$results" || true)"
echo "renovate branches: $passed/$total pass" >&2
