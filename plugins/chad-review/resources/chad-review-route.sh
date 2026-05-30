#!/usr/bin/env bash
# chad-review-route.sh — pick per-pass subagents based on what's in the diff.
#
# WHY THIS EXISTS
# chad-review's 8-pass STRUCTURE is language-agnostic, but the right reviewer
# for each pass depends on the codebase under review. Go cmd Lambdas review
# well with `feature-dev:code-reviewer`; CDK TypeScript wants `cloud-architect`
# for behavioral + adversarial passes; Next.js React wants `frontend-developer`;
# iOS Swift has no native specialist agent so we fall back to `code-reviewer`
# enriched with Context7 docs for the Apple frameworks the diff actually uses.
#
# USAGE
#   bash chad-review-route.sh                     # auto-detect from working tree
#   bash chad-review-route.sh <path-prefix>       # restrict detection to a path
#   bash chad-review-route.sh --last-commit       # detect from last commit
#
# OUTPUT
# Human-readable routing plan: per-pass agent + Context7 hints. Designed for
# the chad-review skill to copy into sub-agent prompts.
#
set -euo pipefail

mode="working-tree"
path_prefix=""
for arg in "$@"; do
  case "$arg" in
    --last-commit) mode="last-commit" ;;
    *) path_prefix="$arg" ;;
  esac
done

# Capture the changed-file list. Tolerate brand-new repos with no HEAD by
# suppressing git stderr; an empty `files` triggers the no-changes path below.
if [[ "$mode" == "last-commit" ]]; then
  files=$(git show --stat --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' || true)
else
  # Three sources: tracked changes vs HEAD, staged-but-not-yet-vs-HEAD, and
  # untracked. Union them — in a brand-new repo with no HEAD the first call
  # errors silently and we rely on the latter two.
  files=$( { git diff HEAD --name-only 2>/dev/null;
             git diff --cached --name-only 2>/dev/null;
             git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )
fi
[[ -n "$path_prefix" ]] && files=$(echo "$files" | grep -F "$path_prefix" || true)

if [[ -z "$files" ]]; then
  echo "No changed files detected."
  exit 0
fi

# Classify by extension and path. A diff can hit multiple partitions; we
# detect each independently so the skill can route per file group.
has_go=$(echo "$files"     | grep -c '\.go$'                              || true)
has_cdk=$(echo "$files"    | grep -cE '(^|/)infrastructure/(lib|bin)/.*\.ts$'  || true)
has_web=$(echo "$files"    | grep -cE '(^|/)web/.*\.(ts|tsx|js|jsx)$'     || true)
has_swift=$(echo "$files"  | grep -c '\.swift$'                           || true)
has_openapi=$(echo "$files" | grep -c '^openapi\.yaml$'                   || true)
has_md=$(echo "$files"     | grep -cE '\.md$'                             || true)
has_cdkjson=$(echo "$files" | grep -cE 'cdk\.json$|package\.json$'        || true)

echo "chad-review routing — $mode"
echo "==========================================="
echo "Files detected:"
[[ "$has_go" -gt 0 ]]      && echo "  Go (.go)               : $has_go"
[[ "$has_cdk" -gt 0 ]]     && echo "  CDK (infra/*.ts)       : $has_cdk"
[[ "$has_web" -gt 0 ]]     && echo "  Web (Next.js/React)    : $has_web"
[[ "$has_swift" -gt 0 ]]   && echo "  iOS Swift              : $has_swift"
[[ "$has_openapi" -gt 0 ]] && echo "  openapi.yaml           : $has_openapi"
[[ "$has_md" -gt 0 ]]      && echo "  Markdown docs          : $has_md"
[[ "$has_cdkjson" -gt 0 ]] && echo "  CDK/npm config         : $has_cdkjson"
echo

# Per-language routing block. Print one block per detected language so the
# chad-review skill can spawn the right agent per file group. All agents run
# on model: "opus" per chad-review's policy.
emit_block() {
  local lang="$1" p1="$2" p2="$3" p3="$4" p5="$5" p6="$6" p7="$7" ctx="$8"
  cat <<EOF
--- Routing: $lang ---
  Pass 1 STRUCTURAL          → $p1
  Pass 2 BEHAVIORAL          → $p2
  Pass 3 SPEC DRIFT          → $p3
  Pass 5 TEST COVERAGE       → $p5
  Pass 6 OBSERVABILITY       → $p6
  Pass 7 DOCUMENTATION       → $p7
EOF
  [[ -n "$ctx" ]] && echo "  Context7 enrichment        → $ctx"
  echo "  (Pass 4 TEST runs in parent; Pass 8 ADVERSARIAL runs in parent)"
  echo
}

# Go cmd Lambdas / shared packages — the partitions 1-4 pattern.
[[ "$has_go" -gt 0 ]] && emit_block "Go (cmd Lambdas / shared)" \
  "Explore (thoroughness: medium)" \
  "feature-dev:code-reviewer" \
  "general-purpose (run scripts/validate-openapi.sh)" \
  "Explore (thoroughness: medium)" \
  "feature-dev:code-reviewer" \
  "general-purpose" \
  ""

# CDK TypeScript — cloud-architect knows IAM patterns, drift, asset paths.
[[ "$has_cdk" -gt 0 ]] && emit_block "CDK TypeScript (infrastructure/)" \
  "Explore (thoroughness: medium)" \
  "cloud-architect" \
  "general-purpose (CFN diff via cdk synth + validate)" \
  "typescript-pro" \
  "cloud-architect" \
  "general-purpose" \
  "context7: aws-cdk-lib (current construct APIs), aws-cloudformation"

# Next.js / React web — frontend-developer + security-auditor for the
# adversarial pass (the parent does Pass 8 inline, but security-auditor can
# also be tagged in if Pass 8 surfaces XSS / CSP / OAuth concerns).
[[ "$has_web" -gt 0 ]] && emit_block "Next.js / React (web/)" \
  "Explore (thoroughness: medium)" \
  "frontend-developer" \
  "general-purpose (openapi spec ↔ types/api.generated.ts)" \
  "frontend-developer" \
  "frontend-developer" \
  "general-purpose" \
  "context7: next.js (App Router), react (Server Components), tanstack-query"

# iOS Swift — no native specialist; use code-reviewer + Context7 for current
# Apple framework semantics (the diff likely touches FoundationModels,
# SpeechAnalyzer, or StoreKit2 — all moving APIs on iOS 26).
[[ "$has_swift" -gt 0 ]] && emit_block "iOS Swift (ios/ReGist/)" \
  "Explore (thoroughness: medium)" \
  "code-reviewer" \
  "general-purpose (validate against openapi.yaml ↔ APIService.swift)" \
  "code-reviewer" \
  "code-reviewer" \
  "general-purpose" \
  "context7: swift (current syntax), apple-foundationmodels (LanguageModelSession), apple-speech (SpeechAnalyzer iOS 26), apple-storekit (StoreKit2)"

# Docs-only or openapi-only diff — lighter touch.
if [[ "$has_go" -eq 0 && "$has_cdk" -eq 0 && "$has_web" -eq 0 && "$has_swift" -eq 0 ]]; then
  if [[ "$has_openapi" -gt 0 || "$has_md" -gt 0 ]]; then
    emit_block "Docs / spec only" \
      "(skip — no symbol removals possible)" \
      "(skip)" \
      "general-purpose (validate-openapi.sh + grep for stale prose refs)" \
      "(skip)" \
      "(skip)" \
      "general-purpose" \
      ""
  fi
fi

echo "==========================================="
echo "Notes:"
echo "  - All sub-agents launched with model: \"opus\" per chad-review policy."
echo "  - Context7 hints are framework names — the agent should resolve to a"
echo "    library ID and fetch docs at audit start, then reason against current"
echo "    semantics (not pre-training knowledge that may be stale)."
echo "  - For mixed-language diffs (e.g., Go + openapi.yaml), spawn one set of"
echo "    agents per language block above. The 8-pass structure is per-language;"
echo "    the parent merges findings into a single Final Report."
