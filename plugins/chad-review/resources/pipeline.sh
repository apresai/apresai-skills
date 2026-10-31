#!/usr/bin/env bash
# pipeline.sh: emit the ultra-audit execution plan for this diff.
#
# One pipeline, no tiers. Every diff gets every review node: the gate,
# the deterministic scans, tests, freshness, a fresh-context Opus
# implementation review, a challenger, per-finding adversarial
# verification, and one gap sweep. Tiers (leaf/deps/small/standard/audit)
# were removed in chad-review 3.0.0 because routing a diff to a lighter
# tier was how findings got skipped.
#
# The only nodes left out are ones with no input to act on: spec-vs-diff
# without a changed PLAN.md, simplify on a diff with no code or with
# executable prompt content (shipping excludes prompts from /simplify),
# and untracked-backup with no untracked files. That is input detection,
# not tiering.
#
# USAGE
#   bash pipeline.sh [--last-commit] [--full]
#   --full is accepted for compatibility and changes nothing: every run is full.
#
# OUTPUT
# One KEY=value block on stdout, then a REASON line. MODE is full or none.
# RISK names high-risk surfaces (auth, migration, api) for the reviewers'
# attention; it no longer changes which nodes run. Exit 0 when a plan was
# produced, including MODE=none. Exit 2 for usage. Exit 1 only when the
# script itself cannot run.
#
# BASH 3.2. No associative arrays, no mapfile. Grep-no-match is normal:
# every command substitution that can match nothing ends in || true.
set -euo pipefail

mode="working-tree"
for arg in "$@"; do
  case "$arg" in
    --full) ;;
    --last-commit) mode="last-commit" ;;
    *) echo "usage: pipeline.sh [--last-commit] [--full]" >&2; exit 2 ;;
  esac
done

ALL_NODES="gate,untracked-backup,docs-drift,contract-mirror,tests,freshness-audit,spec-vs-diff,freshness-update,simplify,docs-apply,skim,impl-review,challenger,verify,sweep,receipt"

empty_plan() {
  echo "MODE=none"
  echo "RISK=none"
  echo "AGENTS=0"
  echo "APPLY=none"
  echo "SPEC=no"
  echo "SCOPE_ASK=0"
  echo "UNTRACKED=$1"
  echo "FILES=0"
  echo "LINES=0"
  echo "LANG_BLOCKS=0"
  echo "NODES="
  echo "SKIP=$ALL_NODES"
  echo "REASON=$2"
  exit 0
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  empty_plan 0 "not a git repository"
fi
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [[ "$mode" == "last-commit" ]]; then
  files=$(git -C "$repo_root" -c core.quotepath=false show --stat --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' || true)
else
  files=$( { git -C "$repo_root" -c core.quotepath=false diff HEAD --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false diff --cached --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null; } | sort -u || true )
fi

untracked=$(git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)
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
    *.go|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.swift|*.py|*.rs|*.kt|*.java|*.rb|*.c|*.h|*.m|*.mm) return 0 ;;
    *.sh|*.bash|*.zsh|*.tf|*.tfvars|*.sql) return 0 ;;
  esac
  return 1
}

is_openapi_path() {
  case "$1" in
    *openapi*|*swagger*) return 0 ;;
  esac
  return 1
}

# --- counts -------------------------------------------------------------------

n_docs=0; n_config=0; n_manifest=0; n_code=0; n_test=0; n_other=0
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

risk_from_path() {
  local f="$1" b
  b=$(basename "$1")
  case "$f" in
    */auth/*|*/oauth/*|*/session/*|*/middleware/*) echo "auth"; return ;;
    */billing/*|*/payment/*|*/payments/*|*/stripe/*|*/crypto/*) echo "auth"; return ;;
    */migrations/*|*schema.prisma*|*/dynamodb*) echo "migration"; return ;;
    *openapi*|*swagger*) echo "api"; return ;;
  esac
  case "$b" in
    auth.go|auth.ts|auth.tsx|auth.js|auth.py|auth.swift|auth.rs) echo "auth"; return ;;
    *oauth*|*jwt*) echo "auth"; return ;;
  esac
  echo ""
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_manifest "$f"; then n_manifest=$((n_manifest+1))
  elif is_config "$f"; then n_config=$((n_config+1))
  elif is_docs "$f"; then n_docs=$((n_docs+1))
  elif is_test "$f"; then n_test=$((n_test+1))
  elif is_code "$f"; then
    n_code=$((n_code+1))
    n_prod_lines=$((n_prod_lines + $(file_lines "$f")))
    rh=$(risk_from_path "$f")
    [[ -n "$rh" ]] && risk_hits+="$rh"$'\n'
  else
    n_other=$((n_other+1))
    if is_openapi_path "$f"; then
      risk_hits+="api"$'\n'
    fi
    rh=$(risk_from_path "$f")
    [[ -n "$rh" ]] && risk_hits+="$rh"$'\n'
  fi
done <<< "$files"

# --- route.sh: exec-md, status-bearing, language blocks -----------------------

route_args=()
[[ "$mode" == "last-commit" ]] && route_args+=(--last-commit)
route_rc=0
route_out=$(bash "$here/chad-review-route.sh" "${route_args[@]+"${route_args[@]}"}" 2>/dev/null) || route_rc=$?

has_exec=0
has_status=0
lang_blocks=0
has_openapi=0
route_failed=0
[[ "$route_rc" -ne 0 ]] && route_failed=1
while IFS= read -r line; do
  case "$line" in
    "--- Routing: Executable prompt content"*) has_exec=1; lang_blocks=$((lang_blocks+1)) ;;
    "--- Routing: Docs / status-bearing"*) has_status=1; lang_blocks=$((lang_blocks+1)) ;;
    "--- Routing: Docs / spec"*) ;;
    "--- Routing: Other"*) lang_blocks=$((lang_blocks+1)) ;;
    "--- Routing:"*) lang_blocks=$((lang_blocks+1)) ;;
    *"OpenAPI spec"*) has_openapi=1 ;;
  esac
done <<< "$route_out"

[[ "$has_openapi" -eq 1 ]] && risk_hits+="api"$'\n'

risk="none"
if [[ -n "$(printf '%s' "$risk_hits" | grep -c . || true)" && "$(printf '%s' "$risk_hits" | grep -c . || true)" -gt 0 ]]; then
  risk=$(printf '%s' "$risk_hits" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
fi

# --- spec presence ------------------------------------------------------------

spec=no
printf '%s\n' "$files" | grep -qxF 'PLAN.md' && spec=yes
printf '%s\n' "$files" | grep -qxF 'plan.md' && spec=yes

# --- size ask -----------------------------------------------------------------

scope_ask=0
if [[ "$file_count" -gt 50 || "$n_prod_lines" -gt 3000 ]]; then
  scope_ask=1
fi

# --- nodes --------------------------------------------------------------------
# Order is load-bearing: backup and gate first, deterministic scans and tests
# on the user's tree, spec before apply (a spec FAIL vetoes docs-apply), apply
# nodes, then every review node sees the post-apply diff.

nodes=""
skip=""
add_node() {
  if [[ -z "$nodes" ]]; then nodes="$1"; else nodes="$nodes,$1"; fi
}
add_skip() {
  if [[ -z "$skip" ]]; then skip="$1"; else skip="$skip,$1"; fi
}

if [[ "$untracked" -gt 0 ]]; then add_node "untracked-backup"; else add_skip "untracked-backup"; fi
add_node "gate"
add_node "docs-drift"
add_node "contract-mirror"
add_node "tests"
add_node "freshness-audit"
if [[ "$spec" == "yes" ]]; then add_node "spec-vs-diff"; else add_skip "spec-vs-diff"; fi
add_node "freshness-update"
if [[ "$has_exec" -eq 0 && "$n_code" -gt 0 ]]; then add_node "simplify"; else add_skip "simplify"; fi
add_node "docs-apply"
add_node "skim"
add_node "impl-review"
add_node "challenger"
add_node "verify"
add_node "sweep"
add_node "receipt"

[[ -z "$skip" ]] && skip="none"

# One impl-review reviewer per routing block (at least one), plus the
# challenger and the sweep. Verifiers scale with the finding count and are
# sized by nodes/verify.md, not here.
agents=$lang_blocks
[[ "$agents" -lt 1 ]] && agents=1
agents=$((agents + 2))

apply=""
printf '%s' ",$nodes," | grep -q ",simplify," && apply="${apply}simplify,"
apply="${apply}docs-stale,deps"

reason="full pipeline"
[[ "$scope_ask" -eq 1 ]] && reason="full pipeline; diff exceeds size ask line"
[[ "$route_failed" -eq 1 ]] && reason="$reason; routing script failed, review the whole diff in one block"

echo "MODE=full"
echo "RISK=$risk"
echo "AGENTS=$agents"
echo "APPLY=$apply"
echo "SPEC=$spec"
echo "SCOPE_ASK=$scope_ask"
echo "UNTRACKED=$untracked"
echo "FILES=$file_count"
echo "LINES=$n_prod_lines"
echo "LANG_BLOCKS=$lang_blocks"
echo "NODES=$nodes"
echo "SKIP=$skip"
echo "REASON=$reason"
