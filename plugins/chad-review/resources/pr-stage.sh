#!/usr/bin/env bash
# pr-stage.sh: stage a whole PR branch as uncommitted changes in a separate,
# read-only review worktree, so every working-tree-mode script (pipeline,
# route, docs-drift, contract-mirror) and the finder/verifier agents review
# the full branch diff, not just HEAD.
#
# WHY: after fix commits the real tree is clean, and --last-commit reviews
# only HEAD while receipt.sh emits a receipt fingerprinted over the whole
# merge-base diff. That GO covered code nobody reviewed.
#
# The staged worktree is a READ lens. The gate, tests, freshness.sh, simplify
# and docs-apply run in the REAL worktree (node_modules, .env and build caches
# live there). Stage after the apply nodes, review the staged dir, then run
# `check` to prove the real tree still holds what was reviewed, then `remove`.
#
# USAGE
#   bash pr-stage.sh stage  [--base <ref>]
#   bash pr-stage.sh check  <dir>
#   bash pr-stage.sh remove <dir>
#
# stage: creates a detached worktree at the merge base under $TMPDIR (made
#   absolute first, so a relative TMPDIR is safe), applies the branch diff
#   plus the real worktree's uncommitted tracked edits as one patch from the
#   merge base, then copies untracked non-ignored files. Nothing is left in
#   the staged index, so committed and uncommitted work all show as changes.
#   Prints, one per line on stdout:
#     DIR=<staged worktree>  BASE=<base ref>  MERGE_BASE=<sha>  HEAD=<sha>
#     BRANCH=<real branch, or "detached">
#     FILES=<count from git status --porcelain -uall in DIR>
#     IGNORED_FORCED=<count>  branch files under gitignored paths (force-added).
#       They are listed on stderr. They are marked intent-to-add in DIR so
#       pipeline.sh and status see them, but review them explicitly.
#     SUBMODULES=<count>  submodule pointer changes, listed on stderr. A
#       gitlink cannot be staged into an uninitialized checkout, so these are
#       not visible in DIR; review them explicitly.
#   Base defaults through the resolver receipt.sh uses (git-common.sh
#   resolve_base_ref): the origin/HEAD symbolic ref, then origin/main,
#   origin/master, main, master.
#   The diff is pinned with receipt.sh's knobs from git-common.sh
#   (core.quotepath=false, diff.noprefix=false, no external diff, no textconv,
#   no color) plus diff.submodule=short, and applied with
#   --whitespace=nowarn, so user config cannot break or skew the stage.
#   Untracked files are enumerated with ls-files -z (non-ASCII names safe);
#   symlinks are copied as symlinks (cp -P), dangling ones included; nested
#   repositories are skipped with a note on stderr. A cleanup trap removes the
#   worktree, patch and temp index when stage fails at any point.
#
# check <dir>: compares the REAL worktree's content (tracked plus untracked
#   non-ignored files, recorded through a temporary GIT_INDEX_FILE so the real
#   index is untouched) with the staged worktree's current content. Exit 0
#   when equal; exit 1 when they differ, printing each differing path on
#   stdout. Submodule and nested-repository entries are not compared (see
#   SUBMODULES). A stray file written into DIR after staging (a verifier
#   repro, coverage output) also reads as a difference: write those elsewhere.
#
# remove <dir>: deletes the staged worktree and its registration. Refuses a
#   directory that pr-stage.sh did not create.
#
# LEAKS: if a session ends between stage and remove (interrupt, crash,
#   context limit), the detached worktree stays registered in `git worktree
#   list`. `remove <dir>` clears a live one; its marker is written right after
#   the worktree is created, so even a partially staged dir is removable. Once
#   the OS clears $TMPDIR, `git worktree prune` (which branch-sweep runs)
#   drops the stale registration. branch-sweep never removes a live worktree.
#
# EXIT: 0 ok; 1 nothing to stage (stage) or content differs (check); 2 usage
#   or any internal failure. Exit 1 never means a failure.
#
# BASH 3.2. No associative arrays, no mapfile.
set -euo pipefail

# shellcheck source=git-common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git-common.sh" \
  || { echo "pr-stage: git-common.sh not found beside pr-stage.sh" >&2; exit 2; }
GITDIFF=(git "${GIT_DIFF_CONFIG[@]}" -c diff.submodule=short "${GIT_DIFF_ARGS[@]}")

usage() { echo "usage: pr-stage.sh stage [--base <ref>] | check <dir> | remove <dir>" >&2; exit 2; }

# --- exit handling: temp cleanup, failed-stage rollback, rc mapping ----------
TMPFILES=()
deliberate=""      # the one non-zero rc that is not a failure (1)
stage_dir=""       # set once the worktree exists; cleared on success
stage_top=""
on_exit() {
  local rc=$? p
  set +e
  for p in ${TMPFILES[@]+"${TMPFILES[@]}"}; do rm -rf "$p"; done
  if [[ -n "$stage_dir" ]]; then
    git -C "$stage_top" worktree remove --force "$stage_dir" >/dev/null 2>&1
    rm -rf "$stage_dir"
    git -C "$stage_top" worktree prune >/dev/null 2>&1
    echo "pr-stage: stage failed; removed the partial worktree $stage_dir" >&2
  fi
  if [[ "$rc" -ne 0 && "$rc" != "$deliberate" ]]; then exit 2; fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 2' INT TERM HUP

die() { echo "pr-stage: $*" >&2; exit 2; }

tmproot() { # absolute temp root, created if missing
  local t="${TMPDIR:-/tmp}"
  mkdir -p "$t" || die "cannot create TMPDIR $t"
  (cd "$t" && pwd -P)
}

newtmp() { # newtmp <var> <root> <name>: sets <var> to a new absolute temp
  # file that the exit trap removes. Never call it inside $(...): the
  # registration would be lost with the subshell.
  local f
  f=$(mktemp "$2/$3.XXXXXX") || die "mktemp failed in $2"
  TMPFILES+=("$f")
  printf -v "$1" '%s' "$f"
}

index_path() { # absolute path of the index of the worktree at $1
  local p
  p=$(git -C "$1" rev-parse --path-format=absolute --git-path index 2>/dev/null) && { printf '%s\n' "$p"; return 0; }
  p=$(git -C "$1" rev-parse --git-path index) || return 1
  case "$p" in /*) ;; *) p="$(cd "$1" && pwd -P)/$p" ;; esac
  printf '%s\n' "$p"
}

marker_dir() { # per-worktree admin dir of a pr-stage worktree, or exit 2
  local d="$1" g
  [[ -n "$d" && -d "$d" ]] || usage
  g=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || die "not a git worktree: $d"
  [[ -f "$g/pr-stage-tree" ]] || die "not a pr-stage worktree: $d"
  printf '%s\n' "$g"
}

staged_tree() { # staged_tree <admin dir> <dir>: the recorded staged tree, or exit 2
  local t
  t=$(cat "$1/pr-stage-tree")
  [[ "$t" != pending ]] || die "staging never finished in $2; remove it"
  printf '%s\n' "$t"
}

is_gitlink() { # is_gitlink <raw meta>: true when either side is mode 160000
  case "$1" in :160000\ *|:*\ 160000\ *) return 0 ;; esac
  return 1
}

# snapshot_tree <worktree> <tmproot>: sets SNAP to a tree object holding
# <worktree>'s content (its index, then add -A), recorded through a temporary
# index so the worktree's own index is never touched.
SNAP=""
snapshot_tree() {
  local wt="$1" root="$2" idx ex=() real top_p
  newtmp idx "$root" pr-stage-index
  real=$(index_path "$wt")
  if [[ -f "$real" ]]; then cp "$real" "$idx"
  else rm -f "$idx"; GIT_INDEX_FILE="$idx" git -C "$wt" read-tree HEAD; fi
  # A temp root inside the worktree must never be recorded as content.
  top_p=$(cd "$wt" && pwd -P)
  case "$root/" in "$top_p"/*) ex=(":(exclude,top)${root#"$top_p"/}") ;; esac
  GIT_INDEX_FILE="$idx" git -C "$wt" -c advice.addEmbeddedRepo=false add -A -- . ${ex[@]+"${ex[@]}"} >/dev/null
  SNAP=$(GIT_INDEX_FILE="$idx" git -C "$wt" write-tree)
}

# paths_between <treeA> <treeB> <git dir to run in>: differing paths, one per
# line, submodule and nested-repo (mode 160000) entries skipped.
paths_between() {
  local meta path
  git -C "$3" -c core.quotepath=false diff-tree -r -z --no-renames --raw "$1" "$2" \
  | while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      is_gitlink "$meta" && continue
      printf '%s\n' "$path"
    done
}

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

case "$cmd" in
  stage)
    base=""
    ulist="" ucopy="" changed="" ignored="" raw="" patch=""   # set by newtmp
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --base) base="${2:-}"; [[ -n "$base" ]] || usage; shift 2 ;;
        *) usage ;;
      esac
    done
    git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"
    git rev-parse -q --verify HEAD >/dev/null 2>&1 || die "no commits yet; nothing has a merge base"
    top=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
    root=$(tmproot)
    cd "$top"
    base=$(resolve_base_ref "$base") \
      || die "no base ref (origin/HEAD, origin/main, origin/master, main, master); pass --base"
    mb=$(git merge-base "$base" HEAD 2>/dev/null) || die "no merge base with $base"
    head=$(git rev-parse HEAD)
    branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo detached)

    # Untracked files, NUL-safe. Nested repos (dir entries) are skipped, and
    # so is a temp root that sits inside the repo.
    tmp_rel=""
    case "$root/" in "$top"/*) tmp_rel="${root#"$top"/}/" ;; esac
    newtmp ulist "$root" pr-stage-untracked
    git -c core.quotepath=false ls-files -z --others --exclude-standard > "$ulist" || die "ls-files failed"
    newtmp ucopy "$root" pr-stage-copy
    n_untracked=0
    while IFS= read -r -d '' f; do
      [[ -n "$f" ]] || continue
      if [[ -n "$tmp_rel" && "$f" == "$tmp_rel"* ]]; then continue; fi
      if [[ "$f" == */ ]]; then echo "pr-stage: skipped nested repository ${f%/} (not reviewed)" >&2; continue; fi
      printf '%s\0' "$f" >> "$ucopy"; n_untracked=$((n_untracked + 1))
    done < "$ulist"

    # One --raw pass answers three questions: is anything tracked changed,
    # which changed paths still exist (for the ignore check), and which rows
    # are submodule pointer changes. The --binary patch is the only other diff.
    newtmp raw "$root" pr-stage-raw
    "${GITDIFF[@]}" --raw -z "$mb" > "$raw" 2>/dev/null || die "git diff against $mb failed"
    if [[ ! -s "$raw" && "$n_untracked" -eq 0 ]]; then
      echo "nothing to stage: HEAD and worktree match $base" >&2
      deliberate=1; exit 1
    fi
    newtmp changed "$root" pr-stage-changed
    n_sub=0; sub_notes=""
    while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
      [[ "${meta##* }" == D ]] || printf '%s\0' "$path" >> "$changed"
      if is_gitlink "$meta"; then
        sub_notes+="pr-stage: submodule pointer change (not visible in DIR, review explicitly): $path ${meta}"$'\n'
        n_sub=$((n_sub + 1))
      fi
    done < "$raw"

    # Ignored-forced: changed, still-present tracked paths matching ignore rules.
    newtmp ignored "$root" pr-stage-ignored
    rc=0; git check-ignore --no-index -z --stdin < "$changed" > "$ignored" || rc=$?
    [[ "$rc" -le 1 ]] || die "git check-ignore failed"
    n_ignored=0
    while IFS= read -r -d '' f; do
      echo "pr-stage: ignored-forced path (review explicitly): $f" >&2; n_ignored=$((n_ignored + 1))
    done < "$ignored"

    # Submodule pointer changes (mode 160000 on either side), after the
    # ignored-forced notes as before.
    printf '%s' "$sub_notes" >&2

    newtmp patch "$root" pr-stage-patch
    "${GITDIFF[@]}" --binary "$mb" > "$patch"

    dir=$(mktemp -d "$root/pr-stage.XXXXXX") || die "mktemp -d failed in $root"
    rmdir "$dir"
    stage_top="$top"; stage_dir="$dir"
    git worktree add -q --detach "$dir" "$mb"
    admin=$(git -C "$dir" rev-parse --absolute-git-dir)
    # Marker first, so remove works on a partially staged dir.
    printf 'pending\n' > "$admin/pr-stage-tree"
    printf '%s\n' "$top" > "$admin/pr-stage-source"

    if [[ -s "$patch" ]]; then
      git -C "$dir" apply --binary --whitespace=nowarn "$patch"
    fi
    while IFS= read -r -d '' f; do
      [[ "$f" == */* ]] && mkdir -p -- "$dir/${f%/*}"
      cp -pP -- "$top/$f" "$dir/$f"
    done < "$ucopy"
    if [[ -s "$ignored" ]]; then
      git -C "$dir" --literal-pathspecs add -N -f --pathspec-from-file="$ignored" --pathspec-file-nul
    fi

    snapshot_tree "$dir" "$root"; tree="$SNAP"
    printf '%s\n' "$tree" > "$admin/pr-stage-tree"
    n=$(git -C "$dir" -c core.quotepath=false status --porcelain -uall -z --no-renames | tr -cd '\000' | wc -c | tr -d ' ')
    stage_dir=""
    echo "DIR=$dir"
    echo "BASE=$base"
    echo "MERGE_BASE=$mb"
    echo "HEAD=$head"
    echo "BRANCH=$branch"
    echo "FILES=${n:-0}"
    echo "IGNORED_FORCED=$n_ignored"
    echo "SUBMODULES=$n_sub"
    ;;
  check)
    dir="${1:-}"; admin=$(marker_dir "$dir")
    staged_tree "$admin" "$dir" >/dev/null
    src=$(cat "$admin/pr-stage-source" 2>/dev/null || true)
    [[ -n "$src" && -d "$src" ]] || die "real worktree for $dir not recorded or missing"
    root=$(tmproot)
    snapshot_tree "$src" "$root"; real_tree="$SNAP"
    snapshot_tree "$dir" "$root"; now_tree="$SNAP"
    diffs=$(paths_between "$real_tree" "$now_tree" "$dir")
    if [[ -z "$diffs" ]]; then
      echo "pr-stage: $src matches the staged content in $dir" >&2
      exit 0
    fi
    printf '%s\n' "$diffs"
    echo "pr-stage: $src differs from the staged content in $dir (paths above)" >&2
    deliberate=1; exit 1
    ;;
  remove)
    dir="${1:-}"; marker_dir "$dir" >/dev/null
    git -C "$dir" worktree remove --force "$dir"
    ;;
  *) usage ;;
esac
