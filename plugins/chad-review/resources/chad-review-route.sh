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

# THE `set -euo pipefail` HAZARD IN THIS SCRIPT. A simple assignment takes the
# exit status of its command substitution, and `pipefail` makes a pipeline take
# the last non-zero status in it. So `x=$(... | grep ...)` aborts the entire
# script whenever grep matches nothing, silently: the user sees truncated output
# and a non-zero exit with no message. A no-match grep is NORMAL here, not an
# error. Every command substitution below that can legitimately match nothing
# therefore ends in `|| true`. Do not remove those without re-reading this.

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not a git repository, so there is no diff to route."
  echo "Run this from inside the repo you want reviewed."
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# Capture the changed-file list. Tolerate brand-new repos with no HEAD by
# suppressing git stderr; an empty `files` triggers the no-changes path below.
if [[ "$mode" == "last-commit" ]]; then
  files=$(git -C "$repo_root" -c core.quotepath=false show --stat --name-only --pretty=format: HEAD 2>/dev/null | grep -v '^$' || true)
else
  # Three sources: tracked changes vs HEAD, staged-but-not-yet-vs-HEAD, and
  # untracked. Union them. In a brand-new repo with no HEAD the first call
  # errors silently and we rely on the latter two. The trailing `|| true` is
  # load-bearing: the group takes its last command's status, and pipefail
  # propagates that through `sort`, so a failing `git ls-files` would abort.
  files=$( { git -C "$repo_root" -c core.quotepath=false diff HEAD --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false diff --cached --name-only 2>/dev/null;
             git -C "$repo_root" -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null; } | sort -u || true )
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
prune=( -name node_modules -o -name .git -o -name .claude -o -name cdk.out -o -name .next -o -name build -o -name dist -o -name DerivedData -o -name vendor )
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
# Pass reviewer="-" for a block that gets no reviewer of its own (prose). It then
# prints neither a tier nor the Phase 2 reviewer line, both of which would
# contradict the block's own "no reviewer" text.
emit_block() {
  local lang="$1" reviewer="$2" spec_hint="$3" ctx="$4"
  echo "--- Routing: $lang ---"
  if [[ "$reviewer" == "-" ]]; then
    echo "  No reviewer of its own: DRIFT [docs] in the parent covers prose."
    echo "      DRIFT hint                         : $spec_hint"
    echo
    return 0
  fi
  cat <<EOF
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
  # `|| true`: a Swift file importing only noise frameworks (Foundation alone is
  # the common case) makes the second grep match nothing, which under pipefail
  # would abort the script before any routing block printed.
  fw=$(echo "$imports" | grep -vE '^$' | grep -vE "$noise" | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
  swift_ctx="context7: swift (current syntax)"
  [[ -n "$fw" ]] && swift_ctx+=" + the frameworks the diff imports: $fw"
  emit_block "iOS / Apple Swift ($(first_dir "$swift_files" || echo ios))" \
    "code-reviewer" \
    "$swift_spec_cmd" \
    "$swift_ctx"
fi

# --- Markdown / spec, with the executable-content carve-out -----------------
# Not all markdown is prose. chad-review forces the `standard` shape for
# CLAUDE.md, any */SKILL.md, anything under .claude/, a prompts/ dir, and a
# plugin's commands|agents|skills dir, because in this ecosystem those files are
# instructions a model executes. They get a real reviewer.
#
# The commands|agents|skills arm needs a boundary: unscoped it swallows ordinary
# prose like `docs/commands/overview.md`, which chad-review classifies as the
# `light` shape with no reviewer at all, and the script and skill would then
# contradict each other. The boundary is a `.claude-plugin/` sibling, which is
# what actually makes a directory a plugin root. A path convention like
# `plugins/*/commands/` would be wrong twice: it misses a plugin published as its
# own repo (commands/ at the root) and it breaks this script's project-agnostic
# promise by hardcoding a directory name.
# Plugin roots are found ONCE, the same way cdk.json and next.config.* are found
# above. Walking ancestors per file with `dirname` forks and a disk stat each
# time measured 11s on a 300-file markdown diff against 0.07s for the pattern
# below; this runs before every review, so that is not an acceptable cost.
#
# The marker is `.claude-plugin/plugin.json`, NOT the `.claude-plugin` directory:
# a marketplace ROOT also has `.claude-plugin/`, holding marketplace.json, so
# matching the directory put "." in this list and short-circuited every
# commands|agents|skills path in the whole repo into executable content. That is
# live in apresai-skills itself.
#
# maxdepth is 8 rather than the 5 used for cdk/next markers above: those sit near
# a project root, whereas a plugin root can be a few levels down in a monorepo
# (marketplace/plugins/<name>/.claude-plugin/plugin.json is already 4).
#
# Path stripping uses parameter expansion, not sed: a repo path containing |, [,
# *, or \ is a valid path but a broken sed expression, and the failure mode was
# silent misrouting rather than an error.
#
# Two accepted limits, both failing toward "route it anyway" rather than a drop:
#   - A `.claude-plugin` reached only through a SYMLINK is not found, since this
#     find does not use -L (which risks loops on a self-referential tree).
#   - A plugin root deeper than maxdepth is not found.
# In both cases a live file falls through to the prose block, which the parent's
# DRIFT [docs] still covers; a deleted one is caught by the git-history check in
# is_exec_md below.
plugin_root_dirs=""
if [[ -n "$md_files$yaml_specs" ]]; then
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    d=${d%/.claude-plugin/plugin.json}
    if [[ "$d" == "$repo_root" ]]; then d="."; else d=${d#"$repo_root"/}; fi
    plugin_root_dirs+="$d"$'\n'
  done < <(find "$repo_root" -maxdepth 8 \( "${prune[@]}" \) -prune -o -path '*/.claude-plugin/plugin.json' -print 2>/dev/null | sort -u || true)
fi

# is_exec_md <repo-relative-path>
# Executable prompt content, per chad-review's forced-`standard` list.
is_exec_md() {
  local f="$1" root
  case "$f" in
    CLAUDE.md|*/CLAUDE.md|SKILL.md|*/SKILL.md) return 0 ;;
    .claude/*|*/.claude/*|prompts/*|*/prompts/*) return 0 ;;
    *"/commands/"*|"commands/"*|*"/agents/"*|"agents/"*|*"/skills/"*|"skills/"*) ;;
    *) return 1 ;;
  esac
  # A commands|agents|skills path counts only as a plugin root's OWN top-level
  # commands/, agents/, or skills/ directory. A bare `$root/*` prefix match also
  # swallowed `$root/vendor/lib/skills/README.md`, and it contradicted the
  # standalone-plugin branch, which was top-level-only. Same rule both ways.
  local pre
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    if [[ "$root" == "." ]]; then pre=""; else pre="$root/"; fi
    case "$f" in
      "$pre"commands/*|"$pre"agents/*|"$pre"skills/*) return 0 ;;
    esac
  done <<< "$plugin_root_dirs"
  # A DELETED file cannot be confirmed from disk, and neither can its plugin root
  # if the whole plugin was deleted with it. Ask git what was there in HEAD
  # instead of guessing: walk the path's `commands|agents|skills` segments and
  # test whether the directory above one held a plugin manifest. Precise in both
  # directions, and it only runs for files that are gone, which are rare.
  if [[ ! -e "$repo_root/$f" ]]; then
    local p="$f" seg cand
    while [[ "$p" == */* ]]; do
      p=${p%/*}
      seg=${p##*/}
      case "$seg" in
        commands|agents|skills)
          if [[ "$p" == */* ]]; then cand="${p%/*}/"; else cand=""; fi
          git -C "$repo_root" cat-file -e "HEAD:${cand}.claude-plugin/plugin.json" 2>/dev/null && return 0
          ;;
      esac
    done
  fi
  return 1
}

# One pass: is_exec_md can shell out to `git cat-file` for deleted files, so
# calling it twice per file doubled that cost on a large plugin deletion.
exec_md=""; prose_md=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if is_exec_md "$f"; then exec_md+="$f"$'\n'; else prose_md+="$f"$'\n'; fi
done <<< "$md_files$yaml_specs"

# Emitted regardless of whether code files are also present. Gating this on a
# code-free diff meant a mixed diff (say a Go change plus CLAUDE.md) counted the
# markdown under "Files detected" and then routed no reviewer for it, which is
# exactly the silent drop this script's header promises never to do.
if [[ -n "$exec_md" ]]; then
  emit_block "Executable prompt content ($(cnt "$exec_md") file(s), $(first_dir "$exec_md" || echo .))" \
    "general-purpose" \
    "${lint_target:+$lint_target + }cross-reference check: every pointer resolves, no stale pass/section names" \
    ""
fi

# Genuine prose and specs, whatever else is in the diff. Emitted even alongside
# code or executable content so no changed file is left unmentioned: a README
# next to a CLAUDE.md, or an OpenAPI spec next to Go, used to vanish from the
# routing entirely, which is the silent drop this script's header rules out.
# `prose_md` is the complement of `exec_md`, both built by the single pass above.
if [[ -n "$prose_md" ]]; then
  emit_block "Docs / spec ($(cnt "$prose_md") file(s), $(first_dir "$prose_md" || echo .))" \
    "-" \
    "${lint_target:+$lint_target + }grep for stale prose refs; DRIFT [docs] is the real work" \
    ""
fi

# --- Unclassified: never drop silently ---------------------------------------
if [[ -n "$other_files" ]]; then
  # `|| true`: unclassified files that all lack an extension (Dockerfile,
  # Makefile) make the grep match nothing. Without the guard the script aborts
  # here and the `${exts:-no extension}` fallback below is never reached.
  exts=$(echo "$other_files" | grep -oE '\.[A-Za-z0-9]+$' | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
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
