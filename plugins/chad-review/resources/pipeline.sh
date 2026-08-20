#!/usr/bin/env bash
# pipeline.sh: emit the ultra-audit execution plan for this diff.
#
# A decision DAG, not a prompt. The parent executes NODES= literally and
# does not re-derive the tier. Ambiguity goes up a tier, never down.
# --full is the only override and it only goes up.
#
# USAGE
#   bash pipeline.sh [--last-commit] [--full]
#
# OUTPUT
# One KEY=value block on stdout, then a REASON line. Always prints TIER
# (none|leaf|deps|small|standard|audit). Exit 0 when a plan was produced,
# including TIER=none. Exit 2 for usage. Exit 1 only when the script itself
# cannot run.
#
# BASH 3.2. No associative arrays, no mapfile. Grep-no-match is normal:
# every command substitution that can match nothing ends in || true.
set -euo pipefail

full=0
mode="working-tree"
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    --last-commit) mode="last-commit" ;;
    *) echo "usage: pipeline.sh [--last-commit] [--full]" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "TIER=none"
  echo "RISK=none"
  echo "FLOORS=none"
  echo "AGENTS=0"
  echo "APPLY=none"
  echo "SPEC=no"
  echo "SCOPE_ASK=0"
  echo "UNTRACKED=0"
  echo "FILES=0"
  echo "LINES=0"
  echo "LANG_BLOCKS=0"
  echo "NODES="
  echo "SKIP=gate,untracked-backup,freshness-audit,freshness-update,docs-drift,contract-mirror,tests,simplify,impl-review,docs-apply,spec-vs-diff,challenger,score,skim,receipt"
  echo "REASON=not a git repository"
  exit 0
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
  echo "TIER=none"
  echo "RISK=none"
  echo "FLOORS=none"
  echo "AGENTS=0"
  echo "APPLY=none"
  echo "SPEC=no"
  echo "SCOPE_ASK=0"
  echo "UNTRACKED=$untracked"
  echo "FILES=0"
  echo "LINES=0"
  echo "LANG_BLOCKS=0"
  echo "NODES="
  echo "SKIP=gate,untracked-backup,freshness-audit,freshness-update,docs-drift,contract-mirror,tests,simplify,impl-review,docs-apply,spec-vs-diff,challenger,score,skim,receipt"
  echo "REASON=nothing to review"
  exit 0
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

# --- floors and tier ----------------------------------------------------------

floors=""
add_floor() {
  if [[ -z "$floors" ]]; then floors="$1"; else floors="$floors,$1"; fi
}

tier=""
scope_ask=0

if [[ "$full" -eq 1 ]]; then
  add_floor "full"
  tier="audit"
fi

if [[ "$risk" != "none" ]]; then
  add_floor "$risk"
  tier="audit"
fi

if [[ "$file_count" -gt 50 || "$n_prod_lines" -gt 3000 ]]; then
  add_floor "size"
  scope_ask=1
  tier="audit"
fi

if [[ "$has_exec" -eq 1 ]]; then
  add_floor "exec-md"
  if [[ -z "$tier" || "$tier" == "leaf" || "$tier" == "deps" || "$tier" == "small" ]]; then
    tier="standard"
  fi
fi

if [[ "$route_failed" -eq 1 ]]; then
  add_floor "route-failed"
  if [[ -z "$tier" || "$tier" == "leaf" || "$tier" == "deps" || "$tier" == "small" ]]; then
    tier="standard"
  fi
fi

if [[ "$has_status" -eq 1 ]]; then
  add_floor "status-docs"
  if [[ -z "$tier" || "$tier" == "leaf" || "$tier" == "deps" || "$tier" == "small" ]]; then
    tier="standard"
  fi
fi

tiny=0
[[ "$file_count" -le 4 && "$n_prod_lines" -le 40 ]] && tiny=1

n_md=$(printf '%s\n' "$files" | grep -c -E '\.(md|mdx)$' || true)
[[ -n "$n_md" ]] || n_md=0

# Manifests plus docs or config is still a deps review: the update node
# is the point. Docs-only / config-only (no code, no tests, no manifests)
# is the only leaf.
deps_only=0
[[ "$n_manifest" -gt 0 && "$n_code" -eq 0 && "$n_test" -eq 0 && "$has_exec" -eq 0 ]] && deps_only=1

no_code=0
[[ "$n_code" -eq 0 && "$n_test" -eq 0 && "$n_manifest" -eq 0 && "$n_other" -eq 0 && "$has_exec" -eq 0 ]] && no_code=1

if [[ -z "$tier" ]]; then
  if [[ "$deps_only" -eq 1 ]]; then
    tier="deps"
  elif [[ "$no_code" -eq 1 ]]; then
    tier="leaf"
  elif [[ "$lang_blocks" -le 1 && "$file_count" -le 15 && "$n_prod_lines" -le 200 ]]; then
    tier="small"
  else
    tier="standard"
  fi
fi

[[ -z "$floors" ]] && floors="none"

# --- nodes --------------------------------------------------------------------

nodes=""
add_node() {
  if [[ -z "$nodes" ]]; then nodes="$1"; else nodes="$nodes,$1"; fi
}

if [[ "$untracked" -gt 0 ]]; then
  add_node "untracked-backup"
fi
add_node "gate"

agents=0
skip=""

case "$tier" in
  leaf)
    # docs-drift is the one deterministic scan a docs-only diff actually
    # needs; skipping it on leaf was a gate regression once ultra-audit
    # receipts began satisfying the merge gate (prune_skip drops it from
    # SKIP when added). Config-only leaves have no markdown and skip it.
    if [[ "$n_md" -gt 0 ]]; then
      add_node "docs-drift"
    fi
    add_node "freshness-audit"
    add_node "skim"
    add_node "receipt"
    agents=0
    skip="freshness-update,docs-drift,contract-mirror,tests,simplify,impl-review,docs-apply,spec-vs-diff,challenger,score"
    ;;
  deps)
    add_node "tests"
    add_node "freshness-audit"
    add_node "freshness-update"
    add_node "receipt"
    agents=0
    skip="docs-drift,contract-mirror,simplify,impl-review,docs-apply,spec-vs-diff,challenger,score,skim"
    ;;
  small)
    add_node "docs-drift"
    add_node "contract-mirror"
    add_node "tests"
    add_node "freshness-audit"
    add_node "freshness-update"
    if [[ "$has_exec" -eq 0 && "$n_code" -gt 0 ]]; then
      add_node "simplify"
    fi
    add_node "docs-apply"
    add_node "impl-review"
    add_node "receipt"
    if [[ "$n_code" -eq 0 || "$tiny" -eq 1 ]]; then
      agents=0
    else
      agents=1
    fi
    skip="spec-vs-diff,challenger,score,skim"
    [[ "$has_exec" -eq 1 || "$n_code" -eq 0 ]] && skip="$skip,simplify"
    ;;
  standard)
    add_node "docs-drift"
    add_node "contract-mirror"
    add_node "tests"
    add_node "freshness-audit"
    add_node "freshness-update"
    if [[ "$has_exec" -eq 0 && "$n_code" -gt 0 ]]; then
      add_node "simplify"
    fi
    add_node "docs-apply"
    add_node "impl-review"
    add_node "score"
    add_node "receipt"
    agents=$lang_blocks
    [[ "$agents" -lt 1 ]] && agents=1
    skip="spec-vs-diff,challenger,skim"
    [[ "$has_exec" -eq 1 || "$n_code" -eq 0 ]] && skip="$skip,simplify"
    ;;
  audit)
    add_node "docs-drift"
    add_node "contract-mirror"
    add_node "tests"
    add_node "freshness-audit"
    if [[ "$spec" == "yes" ]]; then
      add_node "spec-vs-diff"
    fi
    add_node "freshness-update"
    if [[ "$has_exec" -eq 0 && "$n_code" -gt 0 ]]; then
      add_node "simplify"
    fi
    add_node "docs-apply"
    add_node "impl-review"
    add_node "challenger"
    add_node "score"
    add_node "receipt"
    agents=$((lang_blocks + 1))
    [[ "$agents" -lt 2 ]] && agents=2
    skip="skim"
    [[ "$spec" == "no" ]] && skip="$skip,spec-vs-diff"
    [[ "$has_exec" -eq 1 || "$n_code" -eq 0 ]] && skip="$skip,simplify"
    ;;
esac

# Drop skip entries that are actually in NODES.
prune_skip() {
  local s="$1" item
  printf '%s\n' "$s" | tr ',' '\n' | while IFS= read -r item || [[ -n "$item" ]]; do
    [[ -z "$item" ]] && continue
    printf '%s' ",$nodes," | grep -q ",$item," && continue
    printf '%s\n' "$item"
  done | paste -sd, - 2>/dev/null || true
}

skip=$(prune_skip "$skip")
[[ -z "$skip" ]] && skip="none"

apply=""
printf '%s' ",$nodes," | grep -q ",simplify," && apply="${apply}simplify,"
printf '%s' ",$nodes," | grep -q ",docs-apply," && apply="${apply}docs-stale,"
printf '%s' ",$nodes," | grep -q ",freshness-update," && apply="${apply}deps,"
apply=${apply%,}
[[ -z "$apply" ]] && apply="none"

reason=""
case "$tier" in
  none) reason="nothing to review" ;;
  leaf)
    reason="docs or config only, no floors"
    ;;
  deps) reason="manifests and lockfiles only" ;;
  small) reason="one language, modest size, no high-risk floors" ;;
  standard)
    if [[ "$has_exec" -eq 1 ]]; then reason="executable prompt content floors to standard"
    else reason="above small thresholds, not high-risk"; fi
    ;;
  audit)
    if [[ "$full" -eq 1 ]]; then reason="--full"
    elif [[ "$scope_ask" -eq 1 ]]; then reason="diff exceeds size ask line"
    else reason="high-risk floor: $risk"; fi
    ;;
esac

echo "TIER=$tier"
echo "RISK=$risk"
echo "FLOORS=$floors"
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
