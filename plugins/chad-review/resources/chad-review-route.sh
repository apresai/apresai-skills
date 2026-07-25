#!/usr/bin/env bash
# chad-review-route.sh: pick the per-language reviewer based on what's in the diff.
#
# WHY THIS EXISTS
# chad-review's 6-pass STRUCTURE is language-agnostic, but the reviewer that runs
# five of those passes is not: one specialist per language block reads that
# language's hunks once, at the JUDGE tier. Go wants `feature-dev:code-reviewer`;
# CDK TypeScript wants `cloud-architect` (which also covers IaC observability);
# Next.js React wants `frontend-developer`; generic TS wants `typescript-pro`;
# iOS Swift has no native specialist so we fall back to `code-reviewer`, enriched
# with Context7 docs for the frameworks the diff actually imports.
#
# PROJECT-AGNOSTIC BY DESIGN
# This script does NOT assume fixed directory names. It adapts to whatever the
# repo actually looks like:
#   - CDK vs Next.js TypeScript is told apart by IMPORTS (aws-cdk-lib vs next/
#     react) and by marker files (cdk.json / next.config.*), not by a `web/` or
#     `infrastructure/` path.
#   - OpenAPI specs are found by an `openapi:`/`swagger:` key or an `openapi/`
#     dir, not by an exact `openapi.yaml` filename.
#   - Context7 framework hints are DERIVED from the imports / package.json deps
#     the changed files actually use, not a hardcoded per-project list.
#   - SPEC-DRIFT command hints are DERIVED from the project's Makefile targets
#     (gen*, openapi-lint, …) when present.
# Anything it can't classify is still surfaced (no silent drops).
#
# USAGE
#   bash chad-review-route.sh                     # auto-detect from working tree
#   bash chad-review-route.sh <path-prefix>       # restrict detection to a path
#   bash chad-review-route.sh --last-commit       # detect from last commit
#
# OUTPUT
# Human-readable routing plan: per-pass agent + Context7 hints. Designed for
# the chad-review skill to copy into sub-agent prompts. Read-only.
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

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# Capture the changed-file list. Tolerate brand-new repos with no HEAD by
# suppressing git stderr; an empty `files` triggers the no-changes path below.
if [[ "$mode" == "last-commit" ]]; then
  files=$(git show --stat --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' || true)
else
  # Three sources: tracked changes vs HEAD, staged-but-not-yet-vs-HEAD, and
  # untracked. Union them. In a brand-new repo with no HEAD the first call
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# sniff <file> <content-regex> : true if the on-disk file matches the content
# regex. Deleted/renamed-away files won't exist on disk → false.
sniff() { [[ -f "$repo_root/$1" ]] && grep -qE "$2" "$repo_root/$1" 2>/dev/null; }

# first_make_target <regex> : echo `make <target>` for the first Makefile target
# whose name matches, else nothing. Lets DRIFT hints reflect the real repo.
#
# MUST always return 0. Callers assign it (`gen_target=$(first_make_target ...)`),
# and a simple assignment takes the command substitution's exit status, so under
# `set -e` a non-zero return kills the whole script. Ending this function on a
# bare `[[ -n "$t" ]] && echo ...` returns 1 whenever nothing matched, which
# aborted the script in any repo that had a Makefile without a matching target
# (it printed the file counts, then no routing blocks at all, and exited 1).
first_make_target() {
  local mk="$repo_root/Makefile"
  [[ -f "$mk" ]] || return 0
  local t
  t=$(grep -oE "^[a-zA-Z0-9_.-]+:" "$mk" 2>/dev/null | sed 's/:$//' | grep -E "$1" | head -1 || true)
  if [[ -n "$t" ]]; then echo "make $t"; fi
  return 0
}

# first_dir <newline-list> : dirname of the first entry in a classified file
# list, for a human-readable block label (e.g. "ios/Eleven9s").
first_dir() {
  local f
  f=$(echo "$1" | grep -m1 . || true)
  [[ -n "$f" ]] && dirname "$f"
}

# ---------------------------------------------------------------------------
# Classify changed files. TypeScript/JS is split into CDK / web / generic by
# imports first, then by marker-file ancestry, so directory names don't matter.
# ---------------------------------------------------------------------------
go_files=""; swift_files=""; cdk_files=""; web_files=""; ts_files=""
yaml_specs=""; md_files=""; other_files=""

# Pre-locate marker dirs once (pruned find, capped depth) for ancestry fallback.
prune=( -name node_modules -o -name .git -o -name cdk.out -o -name .next -o -name build -o -name dist -o -name DerivedData -o -name vendor )
cdk_marker_dirs=$(find "$repo_root" -maxdepth 5 \( "${prune[@]}" \) -prune -o -name cdk.json -exec dirname {} \; 2>/dev/null | sort -u || true)
next_marker_dirs=$(find "$repo_root" -maxdepth 5 \( "${prune[@]}" \) -prune -o \( -name 'next.config.js' -o -name 'next.config.mjs' -o -name 'next.config.ts' -o -name 'next.config.cjs' \) -exec dirname {} \; 2>/dev/null | sort -u || true)

under_marker() { # under_marker <abs-file-dir> <newline-list-of-dirs>
  local fdir="$1" markers="$2" m
  [[ -z "$markers" ]] && return 1
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    [[ "$fdir" == "$m" || "$fdir" == "$m"/* ]] && return 0
  done <<< "$markers"
  return 1
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.go) go_files+="$f"$'\n'; continue ;;
    *.swift) swift_files+="$f"$'\n'; continue ;;
    *.md|*.mdx) md_files+="$f"$'\n'; continue ;;
    *.ts|*.tsx|*.mts|*.cts|*.js|*.jsx|*.mjs|*.cjs) ;;  # fall through to TS routing
    *.yaml|*.yml)
      if sniff "$f" '^(openapi|swagger):' || [[ "$f" == openapi/* || "$f" == */openapi/* ]]; then
        yaml_specs+="$f"$'\n'
      else
        other_files+="$f"$'\n'
      fi
      continue ;;
    *) other_files+="$f"$'\n'; continue ;;
  esac

  # --- TypeScript/JS: CDK vs web vs generic ---
  if sniff "$f" "aws-cdk-lib|@aws-cdk/|from ['\"]constructs['\"]"; then
    cdk_files+="$f"$'\n'; continue
  fi
  if sniff "$f" "from ['\"]next|from ['\"]react|['\"]use client['\"]|['\"]use server['\"]|next/"; then
    web_files+="$f"$'\n'; continue
  fi
  fdir=$(dirname "$repo_root/$f")
  if under_marker "$fdir" "$cdk_marker_dirs"; then cdk_files+="$f"$'\n'; continue; fi
  if under_marker "$fdir" "$next_marker_dirs"; then web_files+="$f"$'\n'; continue; fi
  ts_files+="$f"$'\n'
done <<< "$files"

cnt() { echo -n "$1" | grep -c . || true; }

echo "chad-review routing: $mode"
echo "==========================================="
echo "Files detected:"
[[ -n "$go_files" ]]    && echo "  Go (.go)                 : $(cnt "$go_files")"
[[ -n "$cdk_files" ]]   && echo "  CDK TypeScript           : $(cnt "$cdk_files")"
[[ -n "$web_files" ]]   && echo "  Next.js / React          : $(cnt "$web_files")"
[[ -n "$ts_files" ]]    && echo "  TypeScript / JS (generic): $(cnt "$ts_files")"
[[ -n "$swift_files" ]] && echo "  iOS / Apple Swift        : $(cnt "$swift_files")"
[[ -n "$yaml_specs" ]]  && echo "  OpenAPI spec             : $(cnt "$yaml_specs")"
[[ -n "$md_files" ]]    && echo "  Markdown docs            : $(cnt "$md_files")"
[[ -n "$other_files" ]] && echo "  Other / unclassified     : $(cnt "$other_files")"
echo

# emit_block <lang> <reviewer_specialist> <spec_hint> <ctx>
# ONE REVIEWER PER LANGUAGE. Passes 1 DRIFT, 2 BEHAVIOR (what changed), 3 TESTS
# (coverage only), 4 OBSERVABILITY, and 6 SIMPLIFY all ride a single per-language
# specialist at the JUDGE tier, reading the diff once. <spec_hint> is the DRIFT
# codegen/spec-lint command hint, surfaced on the reviewer row.
emit_block() {
  local lang="$1" reviewer="$2" spec_hint="$3" ctx="$4"
  cat <<EOF
--- Routing: $lang ---
  Reviewer (DRIFT, BEHAVIOR, TESTS coverage, OBSERVABILITY, SIMPLIFY)
                                       -> $reviewer   [JUDGE tier]
      DRIFT codegen / spec-lint hint     : $spec_hint
EOF
  [[ "$lang" == CDK* ]] && echo "      (+ IaC observability: log retention / X-Ray / alarms folded into the brief)"
  [[ -n "$ctx" ]] && echo "  Context7 enrichment                  -> $ctx"
  echo "  (TESTS run + attacks + filter + verdict -> parent, Phase 2)"
  echo
}

# Detected, project-specific command hints. Prefer an aggregate `gen` target,
# else the first `gen*`; phrase it as the project's codegen entrypoint so the
# reviewing agent runs the language-appropriate sub-target itself.
gen_target=$(first_make_target '^gen$'); [[ -z "$gen_target" ]] && gen_target=$(first_make_target '^gen')
lint_target=$(first_make_target 'openapi-lint|^lint$|validate')
go_spec_cmd="regenerate types${gen_target:+ via $gen_target}${lint_target:+ + $lint_target} + diff generated *.gen.go"
web_spec_cmd="regen API types${gen_target:+ via $gen_target} + diff generated types; tsc --noEmit"
swift_spec_cmd="regen client${gen_target:+ via $gen_target} + diff Generated/ vs the OpenAPI spec"
cdk_spec_cmd="cdk synth + cdk diff after build; or tsc --noEmit"

# --- Go ---------------------------------------------------------------------
[[ -n "$go_files" ]] && emit_block "Go" \
  "feature-dev:code-reviewer" \
  "$go_spec_cmd" \
  ""

# --- CDK TypeScript ---------------------------------------------------------
[[ -n "$cdk_files" ]] && emit_block "CDK TypeScript ($(first_dir "$cdk_files" || echo infra))" \
  "cloud-architect" \
  "$cdk_spec_cmd" \
  "context7: aws-cdk-lib (current construct APIs), aws-cloudformation"

# --- Next.js / React --------------------------------------------------------
if [[ -n "$web_files" ]]; then
  # Derive Context7 hints from the nearest package.json deps to the web files.
  web_dir=$(first_dir "$web_files" || echo .)
  pkg=""; probe="$repo_root/$web_dir"
  while [[ "$probe" == "$repo_root"* ]]; do
    [[ -f "$probe/package.json" ]] && { pkg="$probe/package.json"; break; }
    [[ "$probe" == "$repo_root" ]] && break
    probe=$(dirname "$probe")
  done
  web_ctx="context7:"
  if [[ -n "$pkg" ]]; then
    for lib in next react @tanstack/react-query next-auth tailwindcss zustand zod swr; do
      grep -qE "\"$lib\"" "$pkg" 2>/dev/null && web_ctx+=" ${lib}"
    done
  fi
  [[ "$web_ctx" == "context7:" ]] && web_ctx="context7: next.js (App Router), react (Server Components)"
  emit_block "Next.js / React ($web_dir)" \
    "frontend-developer" \
    "$web_spec_cmd" \
    "$web_ctx"
fi

# --- Generic TypeScript / JS (neither CDK nor Next.js) ----------------------
[[ -n "$ts_files" ]] && emit_block "TypeScript / JS (generic: $(first_dir "$ts_files" || echo .))" \
  "typescript-pro" \
  "tsc --noEmit; regen API types if the project defines codegen" \
  "context7: (resolve from package.json deps the changed files import)"

# --- iOS / Apple Swift ------------------------------------------------------
if [[ -n "$swift_files" ]]; then
  # Derive Context7 hints from the frameworks the CHANGED Swift files import,
  # skipping ubiquitous ones that don't need a doc-fetch.
  imports=""
  while IFS= read -r f; do
    [[ -z "$f" || ! -f "$repo_root/$f" ]] && continue
    imports+=$(grep -hoE "^[[:space:]]*import [A-Za-z_][A-Za-z0-9_]*" "$repo_root/$f" 2>/dev/null | sed -E 's/^[[:space:]]*import //' || true)$'\n'
  done <<< "$swift_files"
  noise='^(Foundation|Combine|OSLog|os|Dispatch|CoreFoundation|CoreGraphics|CoreData|UIKit|SwiftUI|Observation|Security|Darwin)$'
  fw=$(echo "$imports" | grep -vE '^$' | grep -vE "$noise" | sort -u | tr '\n' ' ' | sed 's/ *$//')
  swift_ctx="context7: swift (current syntax)"
  [[ -n "$fw" ]] && swift_ctx+=" + the frameworks the diff imports: $fw"
  emit_block "iOS / Apple Swift ($(first_dir "$swift_files" || echo ios))" \
    "code-reviewer" \
    "$swift_spec_cmd" \
    "$swift_ctx"
fi

# --- OpenAPI-spec-only / docs-only lighter touch ----------------------------
if [[ -z "$go_files$cdk_files$web_files$ts_files$swift_files" ]]; then
  if [[ -n "$yaml_specs$md_files" ]]; then
    emit_block "Docs / spec only" \
      "(skip: the light diff shape runs every pass inline in the parent)" \
      "${lint_target:+$lint_target + }grep for stale prose refs; DRIFT [docs] is the real work" \
      ""
  fi
fi

# --- Unclassified: never drop silently ---------------------------------------
if [[ -n "$other_files" ]]; then
  exts=$(echo "$other_files" | grep -oE '\.[A-Za-z0-9]+$' | sort -u | tr '\n' ' ' | sed 's/ *$//')
  echo "--- Routing: Other / unclassified (${exts:-no extension}) ---"
  echo "  No language specialist matched these. Review with general-purpose"
  echo "  (+ code-reviewer for any executable code). Do NOT skip them."
  echo
fi

echo "==========================================="
echo "Notes:"
echo "  - Model tiering is SESSION-RELATIVE (chad-review \"Model tiering\"): MECH is"
echo "    always sonnet; JUDGE is opus except on a sonnet session, which stays"
echo "    sonnet everywhere. Never haiku, never spawn fable. The reviewer rides"
echo "    JUDGE; FRESHNESS rides MECH."
echo "  - FRESHNESS -> general-purpose [MECH], whole-project: launch it ONCE per"
echo "    review, not per language block, and not from the routing above."
echo "  - Phase 2 is the parent: run the affected tests, run the attack probes,"
echo "    filter every finding once, re-verify CRITICALs, write the verdict."
echo "  - Context7 hints are framework names. The agent resolves each to a library"
echo "    ID and fetches docs at audit start, then reasons against current"
echo "    semantics rather than pre-training knowledge that may be stale."
echo "  - Mixed-language diffs: one reviewer per block above, each scoped to ONLY"
echo "    that block's hunks, plus one whole-project FRESHNESS agent. The parent"
echo "    merges every finding into a single Final Report."
