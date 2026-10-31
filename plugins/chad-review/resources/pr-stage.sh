#!/usr/bin/env bash
# pr-stage.sh: stage a whole PR branch as uncommitted changes so every
# working-tree-mode script (pipeline, route, docs-drift, contract-mirror)
# reviews the full branch diff, not just HEAD.
#
# WHY: after fix commits the real tree is clean, and --last-commit reviews
# only HEAD while receipt.sh emits a receipt fingerprinted over the whole
# merge-base diff. That GO covered code nobody reviewed.
#
# USAGE
#   bash pr-stage.sh stage  [--base <ref>]   # prints DIR=, MERGE_BASE=, HEAD=, FILES=
#   bash pr-stage.sh export <dir>            # prints a patch of edits made in <dir> since staging
#   bash pr-stage.sh remove <dir>
#
# stage: creates a detached worktree at the merge base under $TMPDIR, applies
# the branch diff (base..HEAD) plus the real worktree's uncommitted changes,
# then unstages, so committed and uncommitted work both show as changes. The
# staged state is recorded as a tree object so export can isolate edits that
# apply nodes (simplify, docs-apply) or anyone else made afterwards.
# Base defaults to origin/main, then main. Exit 0 ok, 1 nothing to stage, 2 usage
# or cannot run.
set -euo pipefail

usage() { echo "usage: pr-stage.sh stage [--base <ref>] | export <dir> | remove <dir>" >&2; exit 2; }
cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

case "$cmd" in
  stage)
    base=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --base) base="${2:-}"; [[ -n "$base" ]] || usage; shift 2 ;;
        *) usage ;;
      esac
    done
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }
    top=$(git rev-parse --show-toplevel)
    if [[ -z "$base" ]]; then
      if git rev-parse -q --verify origin/main >/dev/null 2>&1; then base=origin/main
      elif git rev-parse -q --verify main >/dev/null 2>&1; then base=main
      else echo "no base ref; pass --base" >&2; exit 2; fi
    fi
    mb=$(git merge-base "$base" HEAD 2>/dev/null) || { echo "no merge base with $base" >&2; exit 2; }
    head=$(git rev-parse HEAD)
    patch=$(mktemp "${TMPDIR:-/tmp}/pr-stage-patch.XXXXXX")
    # Committed branch work plus uncommitted tracked edits, as one diff from the merge base.
    git -C "$top" diff --binary "$mb" > "$patch"
    untracked=$(git -C "$top" ls-files --others --exclude-standard)
    if [[ ! -s "$patch" && -z "$untracked" ]]; then
      rm -f "$patch"; echo "nothing to stage: HEAD and worktree match $base" >&2; exit 1
    fi
    dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-stage.XXXXXX")
    rmdir "$dir"
    git -C "$top" worktree add -q --detach "$dir" "$mb"
    if [[ -s "$patch" ]]; then git -C "$dir" apply --binary "$patch"; fi
    rm -f "$patch"
    # Untracked files in the real tree are part of the change too.
    if [[ -n "$untracked" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        mkdir -p "$dir/$(dirname "$f")"
        cp -p "$top/$f" "$dir/$f"
      done <<< "$untracked"
    fi
    # Record the staged state without leaving anything staged.
    git -C "$dir" add -A
    tree=$(git -C "$dir" write-tree)
    git -C "$dir" reset -q
    printf '%s\n' "$tree" > "$(git -C "$dir" rev-parse --git-dir)/pr-stage-tree"
    n=$(git -C "$dir" status --porcelain | grep -c . || true)
    echo "DIR=$dir"
    echo "BASE=$base"
    echo "MERGE_BASE=$mb"
    echo "HEAD=$head"
    echo "FILES=${n:-0}"
    ;;
  export)
    dir="${1:-}"; [[ -n "$dir" && -d "$dir" ]] || usage
    marker="$(git -C "$dir" rev-parse --git-dir)/pr-stage-tree"
    [[ -f "$marker" ]] || { echo "not a pr-stage worktree: $dir" >&2; exit 2; }
    tree=$(cat "$marker")
    git -C "$dir" add -A
    git -C "$dir" diff --cached --binary "$tree"
    git -C "$dir" reset -q
    ;;
  remove)
    dir="${1:-}"; [[ -n "$dir" && -d "$dir" ]] || usage
    marker="$(git -C "$dir" rev-parse --git-dir)/pr-stage-tree"
    [[ -f "$marker" ]] || { echo "not a pr-stage worktree: $dir" >&2; exit 2; }
    git -C "$dir" worktree remove --force "$dir"
    ;;
  *) usage ;;
esac
