#!/usr/bin/env bash
# pipeline.sh: emit the ultra-audit execution plan for this diff.
#
# Two depths, one rule. Depth decides how many agents LOOK; it never decides
# which findings are KEPT. Every finding from either depth goes through
# evidence-required verification and, unless refuted, gets fixed (3.0.0).
#
#   fast (default): gate, deterministic scans, tests, freshness audit, skim,
#     one Opus finder over the whole diff, verify.
#   deep: the whole-diff finder is REPLACED by one finder per routing block
#     (prose blocks included), plus a fresh-context challenger and one gap
#     sweep. Chosen when a high-risk path is touched (auth, billing, crypto,
#     migrations, OpenAPI), when the diff carries executable prompt content,
#     when it carries status-bearing docs (route's "Docs / status-bearing"
#     block; that block's finder reads each flagged doc in full, since a stale
#     "Status: Active" line is rarely inside the hunks), when it passes 15
#     files or 400 production lines, when routing failed, or with --full.
#
# Dependency UPDATES are not part of review. /deps-update does them as their
# own PR. Review only audits (freshness-audit).
#
# Input-driven omissions, not depth: spec-vs-diff needs a changed PLAN.md;
# simplify needs production code and a working route (so prompt files are
# known and excluded). Test files, manifests, config and docs are not
# production code here, so a test-only diff skips simplify by design.
# untracked-backup needs untracked files in the REAL worktree.
#
# STAGED REVIEW. A multi-commit PR branch is reviewed whole by running this
# inside the worktree pr-stage.sh creates, never with --last-commit on a fix
# commit. Pass --staged <real-worktree> there. In the staged worktree every
# file the branch added shows as untracked (pr-stage leaves nothing staged),
# so its untracked list is the diff, not uncommitted work. With --staged the
# staged dir's files and line counts still drive the plan, but UNTRACKED and
# the untracked-backup node come from <real-worktree>, where the backup, the
# apply nodes and untracked-guard verify --restore run.
#
# USAGE
#   bash pipeline.sh [--last-commit] [--full]
#   bash pipeline.sh --staged <real-worktree> [--full]   # inside a pr-stage.sh dir
#
# OUTPUT
# One KEY=value block on stdout, then a REASON line. MODE is fast, deep, or
# none. Exit 0 when a plan was produced, including MODE=none. Exit 2 for
# usage (including --staged without a git worktree, or with --last-commit).
# Exit 1 only when the script itself cannot run.
#
# BASH 3.2. No associative arrays, no mapfile. Grep-no-match is normal:
# every command substitution that can match nothing ends in || true.
set -euo pipefail

usage() { echo "usage: pipeline.sh [--last-commit] [--full] | --staged <real-worktree> [--full]" >&2; exit 2; }
full=0
mode="working-tree"
staged_real=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) full=1; shift ;;
    --last-commit) mode="last-commit"; shift ;;
    --staged) [[ $# -ge 2 && -n "$2" ]] || usage; staged_real="$2"; shift 2 ;;
    *) usage ;;
  esac
done
# Resolved once: the --staged same-dir check and the scans below both use it.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n "$staged_real" ]]; then
  [[ "$mode" == "last-commit" ]] && usage
  staged_real=$(git -C "$staged_real" rev-parse --show-toplevel 2>/dev/null) || {
    echo "pipeline.sh: --staged needs the real git worktree" >&2; usage; }
  # Passing the staged dir itself would bring back the miscount --staged exists to fix.
  if [[ "$staged_real" == "$repo_root" ]]; then
    echo "pipeline.sh: --staged takes the REAL worktree, not the staged dir" >&2; usage
  fi
fi

ALL_NODES="untracked-backup,gate,tests,freshness-audit,spec-vs-diff,simplify,docs-apply,docs-drift,contract-mirror,skim,impl-review,challenger,verify,sweep,receipt"

empty_plan() {
  echo "MODE=none"
  echo "RISK=none"
  echo "AGENTS=0"
  echo "SPEC=no"
  echo "SCOPE_ASK=0"
  echo "UNTRACKED=$1"
  echo "FILES=0"
  echo "LINES=0"
  echo "LANG_BLOCKS=0"
  echo "PROSE_BLOCKS=0"
  echo "NODES="
  echo "SKIP=$ALL_NODES"
  echo "REASON=$2"
  exit 0
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  empty_plan 0 "not a git repository"
fi
[[ -n "$repo_root" ]] || repo_root="."
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "$mode" == "last-commit" ]]; then
  files=$(git -C "$repo_root" -c core.quotepath=false show --stat --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' || true)
else
  files=$( { git -C "$repo_root" -c core.quotepath=false diff HEAD --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false diff --cached --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null; } | sort -u || true )
fi

# The backup protects the REAL worktree's untracked files. In a staged
# worktree (--staged) the local untracked list is the branch diff itself.
untracked_root="$repo_root"
[[ -n "$staged_real" ]] && untracked_root="$staged_real"
untracked=$(git -C "$untracked_root" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)
[[ -n "$untracked" ]] || untracked=0

file_count=$(printf '%s' "$files" | grep -c . || true)
[[ -n "$file_count" ]] || file_count=0

if [[ "$file_count" -eq 0 ]]; then
  empty_plan "$untracked" "nothing to review"
fi

# --- kind predicates ----------------------------------------------------------

is_manifest() {
  local b
  b=$(basename "$1")
  case "$b" in
    go.mod|go.sum|package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|npm-shrinkwrap.json) return 0 ;;
    pubspec.yaml|pubspec.lock|Package.swift|Package.resolved|Cargo.toml|Cargo.lock) return 0 ;;
    pyproject.toml|poetry.lock|Pipfile|Pipfile.lock|Gemfile|Gemfile.lock|composer.json|composer.lock) return 0 ;;
    requirements.txt|requirements-*.txt) return 0 ;;
  esac
  case "$b" in
    requirements*.txt) return 0 ;;
  esac
  return 1
}

is_config() {
  case "$1" in
    .github/*|.gitignore|.gitattributes|.editorconfig|.eslintrc|.eslintrc.*|eslint.config.*|.prettierrc|.prettierrc.*|.golangci.yml|.golangci.yaml|.swiftlint.yml) return 0 ;;
  esac
  return 1
}

is_docs() {
  case "$1" in
    *.md|*.mdx|*.txt|docs/*|*/docs/*|LICENSE|LICENSE.*|*.png|*.jpg|*.jpeg|*.gif|*.svg|*.webp) return 0 ;;
  esac
  return 1
}

is_test() {
  local b
  b=$(basename "$1")
  case "$1" in
    */testdata/*|*/__tests__/*|*/tests/*) return 0 ;;
  esac
  case "$b" in
    *_test.go|*.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) return 0 ;;
    test_*.py|*_test.py|*Tests.swift|*Test.swift|*_test.rs) return 0 ;;
  esac
  return 1
}

is_code() {
  local b
  b=$(basename "$1")
  case "$b" in
    Makefile|Dockerfile|Justfile|Taskfile.yml) return 0 ;;
  esac
  case "$1" in
    *.go|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.swift|*.py|*.rs|*.kt|*.kts|*.java|*.rb|*.c|*.h|*.cc|*.cpp|*.hpp|*.m|*.mm) return 0 ;;
    *.dart|*.vue|*.svelte|*.cs|*.php|*.scala|*.ex|*.exs|*.lua|*.pl|*.r|*.R) return 0 ;;
    *.sh|*.bash|*.zsh|*.tf|*.tfvars|*.sql) return 0 ;;
  esac
  return 1
}

# --- counts -------------------------------------------------------------------

n_code=0
n_prod_lines=0
risk_hits=""

file_lines() {
  local f="$1" n=0
  if [[ "$mode" == "last-commit" ]]; then
    n=$(git -C "$repo_root" show --numstat --pretty=format: HEAD -- "$f" 2>/dev/null | awk '{a+=$1+$2} END {print a+0}' || true)
  else
    n=$(git -C "$repo_root" diff HEAD --numstat -- "$f" 2>/dev/null | awk '{a+=$1+$2} END {print a+0}' || true)
    if [[ "${n:-0}" -eq 0 ]]; then
      n=$(git -C "$repo_root" diff --cached --numstat -- "$f" 2>/dev/null | awk '{a+=$1+$2} END {print a+0}' || true)
    fi
    if [[ "${n:-0}" -eq 0 && -f "$repo_root/$f" ]]; then
      local ut
      ut=$(git -C "$repo_root" ls-files --others --exclude-standard -- "$f" 2>/dev/null || true)
      [[ -n "$ut" ]] && n=$(wc -l < "$repo_root/$f" 2>/dev/null | tr -d ' ' || true)
    fi
  fi
  echo "${n:-0}"
}

# risk_from_path <path>: prints auth, migration, api, or nothing. Matching
# "/$f" lets one */dir/* pattern cover a top-level dir and a nested one.
risk_from_path() {
  case "/$1" in
    */auth/*|*/oauth/*|*/session/*|*/middleware/*) echo "auth"; return ;;
    */billing/*|*/payment/*|*/payments/*|*/stripe/*|*/crypto/*) echo "auth"; return ;;
    */migrations/*|*schema.prisma*|*/dynamodb*) echo "migration"; return ;;
    *openapi*|*swagger*) echo "api"; return ;;
  esac
  local b="${1%/}"
  case "${b##*/}" in
    auth.go|auth.ts|auth.tsx|auth.js|auth.py|auth.swift|auth.rs) echo "auth"; return ;;
    *oauth*|*jwt*) echo "auth"; return ;;
  esac
}

# Manifests, config, docs and tests carry no path risk and no production
# lines. Everything else is risk-checked; code also counts toward size. A
# non-code openapi/swagger path is api even when an earlier rule (auth/,
# migrations/) claims it first in risk_from_path.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_manifest "$f" || is_config "$f" || is_docs "$f" || is_test "$f"; then continue; fi
  if is_code "$f"; then
    n_code=$((n_code+1))
    n_prod_lines=$((n_prod_lines + $(file_lines "$f")))
  else
    case "$f" in *openapi*|*swagger*) risk_hits+="api"$'\n' ;; esac
  fi
  rh=$(risk_from_path "$f")
  [[ -n "$rh" ]] && risk_hits+="$rh"$'\n'
done <<< "$files"

# --- route.sh: exec-md, status-bearing, language blocks -----------------------

route_args=()
[[ "$mode" == "last-commit" ]] && route_args+=(--last-commit)
route_rc=0
route_out=$(bash "$here/chad-review-route.sh" "${route_args[@]+"${route_args[@]}"}" 2>/dev/null) || route_rc=$?

has_exec=0
has_status=0
lang_blocks=0
prose_blocks=0
has_openapi=0
route_failed=0
[[ "$route_rc" -ne 0 ]] && route_failed=1
while IFS= read -r line; do
  case "$line" in
    "--- Routing: Executable prompt content"*) has_exec=1; lang_blocks=$((lang_blocks+1)) ;;
    "--- Routing: Docs / status-bearing"*) has_status=1; lang_blocks=$((lang_blocks+1)) ;;
    "--- Routing: Docs / spec"*) prose_blocks=$((prose_blocks+1)) ;;
    "--- Routing:"*) lang_blocks=$((lang_blocks+1)) ;;
    # Only route's "Files detected" count line. A bare *"OpenAPI spec"* also
    # matched the Swift codegen hint ("... vs the OpenAPI spec"), so every
    # Swift diff went RISK=api.
    "  OpenAPI spec             : "*) has_openapi=1 ;;
  esac
done <<< "$route_out"

[[ "$has_openapi" -eq 1 ]] && risk_hits+="api"$'\n'

risk="none"
if [[ -n "$(printf '%s' "$risk_hits" | grep -c . || true)" && "$(printf '%s' "$risk_hits" | grep -c . || true)" -gt 0 ]]; then
  risk=$(printf '%s' "$risk_hits" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
fi

# --- spec presence ------------------------------------------------------------

spec=no; spec_on=0
if grep -qxF -e 'PLAN.md' -e 'plan.md' <<< "$files"; then spec=yes; spec_on=1; fi

# --- size ask and depth --------------------------------------------------------

scope_ask=0
if [[ "$file_count" -gt 50 || "$n_prod_lines" -gt 3000 ]]; then
  scope_ask=1
fi

# append <var> <separator> <item>: add item to the list held in var.
append() { if [[ -z "${!1}" ]]; then printf -v "$1" '%s' "$3"; else printf -v "$1" '%s%s%s' "${!1}" "$2" "$3"; fi; }

depth="fast"
why=""
[[ "$full" -eq 1 ]] && append why ", " "--full"
[[ "$risk" != "none" ]] && append why ", " "risk: $risk"
[[ "$has_exec" -eq 1 ]] && append why ", " "executable prompt content"
[[ "$has_status" -eq 1 ]] && append why ", " "status-bearing docs"
[[ "$file_count" -gt 15 ]] && append why ", " "$file_count files"
[[ "$n_prod_lines" -gt 400 ]] && append why ", " "$n_prod_lines production lines"
[[ "$route_failed" -eq 1 ]] && append why ", " "routing failed"
[[ -n "$why" ]] && depth="deep"

# Finder agents before verification. fast: one reviewer over the whole diff.
# deep: one per routing block in place of it, prose blocks included, plus
# challenger and sweep, plus spec-vs-diff when listed. Verifiers scale with the finding
# count (nodes/verify.md) and are not counted here.
if [[ "$depth" == "deep" ]]; then
  deep=1
  agents=$((lang_blocks + prose_blocks))
  [[ "$agents" -lt 1 ]] && agents=1
  agents=$((agents + 2))
  reason="deep: $why"
else
  deep=0
  agents=1
  reason="fast: no high-risk path, no prompt content, no status-bearing docs, small diff"
fi
[[ "$spec" == "yes" ]] && agents=$((agents + 1))
[[ "$scope_ask" -eq 1 ]] && reason="$reason; diff exceeds size ask line"

# --- nodes --------------------------------------------------------------------
# Order is load-bearing. backup, gate, tests and freshness-audit run in the
# REAL worktree; spec-vs-diff before apply (a spec FAIL vetoes docs-apply);
# the apply nodes (simplify, docs-apply) edit the real worktree and the gate
# re-runs there. Then the parent stages (pr-stage.sh stage) for a branch
# review, and the scans (docs-drift, contract-mirror), skim, every finder and
# verify read the post-apply content. receipt last.

nodes=""
skip=""
# plan_node <name> [0|1]: list the node (flag 1 or absent), else record it skipped.
plan_node() { if [[ "${2:-1}" -eq 1 ]]; then append nodes "," "$1"; else append skip "," "$1"; fi; }

plan_node untracked-backup "$(( untracked > 0 ))"
plan_node gate
plan_node tests
plan_node freshness-audit
plan_node spec-vs-diff "$spec_on"
# simplify needs production code (n_code excludes tests, manifests, config and
# docs), and a working route so prompt files are known and excluded from it.
# Mixed prompt-plus-code diffs simplify the code files only.
plan_node simplify "$(( n_code > 0 && route_failed == 0 ))"
plan_node docs-apply
plan_node docs-drift
plan_node contract-mirror
plan_node skim
plan_node impl-review
plan_node challenger "$deep"
plan_node verify
plan_node sweep "$deep"
plan_node receipt
[[ -z "$skip" ]] && skip="none"

echo "MODE=$depth"
echo "RISK=$risk"
echo "AGENTS=$agents"
echo "SPEC=$spec"
echo "SCOPE_ASK=$scope_ask"
echo "UNTRACKED=$untracked"
echo "FILES=$file_count"
echo "LINES=$n_prod_lines"
echo "LANG_BLOCKS=$lang_blocks"
echo "PROSE_BLOCKS=$prose_blocks"
echo "NODES=$nodes"
echo "SKIP=$skip"
echo "REASON=$reason"
