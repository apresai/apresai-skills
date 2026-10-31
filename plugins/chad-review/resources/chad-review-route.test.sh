#!/usr/bin/env bash
# chad-review-route.test.sh: suite for chad-review-route.sh.
#
# WHY THIS EXISTS
# The routing script had no tests at all, which is how two classes of miss
# lived in it unnoticed. First, every changed markdown file routed either to
# "executable prompt content" or to "no reviewer of its own", so a doc carrying
# a historical banner AND a "Status: Active" line, and a device checklist
# recommending "build 117/118 or later" against an authoritative build of 152,
# both sailed through with no reviewer. Second, nothing locked the existing
# behavior (every language block to general-purpose, exec markdown too,
# the exact prose-block wording the skill quotes), so any of it could regress
# silently. This suite locks the new three-way markdown partition (exec beats
# status beats prose), the DOCS-DRIFT-TASK line the parent executes during
# DRIFT, and the pre-existing routing contract.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chad-review-route.sh"
pass=0; fail=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <desc> <expected-substring> <actual>
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}
absent(){ # absent <desc> <substring-that-must-not-appear> <actual>
  if grep -qF -- "$2" <<<"$3"; then
    bad "$1"; printf '       must NOT contain: %s\n' "$2"
  else ok "$1"; fi
}

newrepo(){ local d; d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }
run(){ ( cd "$1" && shift && bash "$SCRIPT" "$@" 2>&1 ); }

# --- 1. trivial docs typo routes to the prose block, reviewer "-" ------------
r=$(newrepo)
printf 'A readme.\n\nJust three plain lines.\n' > "$r/README.md"
out=$(run "$r")
check "trivial typo doc lands in the prose block" "Routing: Docs / spec" "$out"
check "prose block keeps the no-reviewer wording" "No reviewer of its own: DRIFT [docs] in the parent covers prose." "$out"
absent "trivial typo doc does not get the status block" "Docs / status-bearing" "$out"
rm -rf "$r"

# --- 2. status-bearing docs-only gets its own sonnet reviewer ----------------
r=$(newrepo)
{ printf '# Plan\n\n**Status:** Active plan.\n\n'
  printf -- '- [ ] first box\n- [x] second box\n'
} > "$r/plan.md"
out=$(run "$r")
check "status-bearing doc gets its own block" "Routing: Docs / status-bearing" "$out"
check "status reviewer is general-purpose" "general-purpose" "$out"
check "status reviewer rides REVIEW tier sonnet" "[REVIEW tier, sonnet]" "$out"
check "status block hint names docs-drift.sh" "docs-drift.sh" "$out"
rm -rf "$r"

# --- 3. substantial-by-size arm: marker-free but big -------------------------
r=$(newrepo)
: > "$r/notes.md"
i=1; while [[ $i -le 60 ]]; do printf 'filler prose line %s about nothing in particular\n' "$i" >> "$r/notes.md"; i=$((i+1)); done
out=$(run "$r")
check "60 marker-free lines still route status-bearing" "Routing: Docs / status-bearing" "$out"
rm -rf "$r"

# --- 4. mixed md+ts: docs task line AND the ts reviewer ----------------------
r=$(newrepo)
printf 'export const x = 1\n' > "$r/foo.ts"
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r")
check "mixed diff emits the docs DRIFT task" "DOCS-DRIFT-TASK" "$out"
check "docs task names the script to run" "docs-drift.sh" "$out"
check "mixed diff still routes generic TS" "Routing: TypeScript / JS" "$out"
check "generic TS reviewer is general-purpose" "-> general-purpose   [REVIEW tier, sonnet]" "$out"
rm -rf "$r"

# --- 5. docs-only diff also gets the task line -------------------------------
r=$(newrepo)
printf '**Status:** Active.\n' > "$r/plan.md"
out=$(run "$r")
check "docs-only diff emits the docs DRIFT task" "DOCS-DRIFT-TASK" "$out"
rm -rf "$r"

# --- 6. regression: executable prompt content routes to general-purpose ------
r=$(newrepo)
mkdir -p "$r/.claude-plugin" "$r/commands"
printf '{"name":"p"}\n' > "$r/.claude-plugin/plugin.json"
printf '# a command\n' > "$r/commands/x.md"
out=$(run "$r")
check "exec markdown gets its own block" "Executable prompt content" "$out"
check "exec markdown reviewer is general-purpose" "general-purpose" "$out"
rm -rf "$r"

# --- 6b. AGENTS.md and Claude.md are executable mirrors of CLAUDE.md ---------
r=$(newrepo)
printf '# Codex mirror\n' > "$r/AGENTS.md"
out=$(run "$r")
check "AGENTS.md is executable prompt content" "Executable prompt content" "$out"
rm -rf "$r"
r=$(newrepo)
printf '# Claude mirror\n' > "$r/Claude.md"
out=$(run "$r")
check "Claude.md is executable prompt content" "Executable prompt content" "$out"
rm -rf "$r"

# --- 7. every language block routes to general-purpose ---------------------
r=$(newrepo)
printf 'package main\n' > "$r/main.go"
out=$(run "$r")
check "Go gets its own block" "Routing: Go" "$out"
check "Go reviewer is general-purpose" "-> general-purpose   [REVIEW tier, sonnet]" "$out"
rm -rf "$r"
r=$(newrepo)
printf "import SwiftUI\n" > "$r/App.swift"
out=$(run "$r")
check "Swift still gets a route" "Routing: iOS / Apple Swift" "$out"
check "Swift reviewer is general-purpose" "-> general-purpose   [REVIEW tier, sonnet]" "$out"
rm -rf "$r"
r=$(newrepo)
printf "export const x = 1\n" > "$r/foo.ts"
printf "package main\n" > "$r/main.go"
printf "import Foundation\n" > "$r/A.swift"
out=$(run "$r")
for old in feature-dev:code-reviewer cloud-architect frontend-developer typescript-pro "-> code-reviewer"; do
  absent "no block routes to retired agent $old" "$old" "$out"
done
rm -rf "$r"

# --- 8. exec beats status: a command file full of status markers -------------
r=$(newrepo)
mkdir -p "$r/plugins/p/.claude-plugin" "$r/plugins/p/commands"
printf '{"name":"p"}\n' > "$r/plugins/p/.claude-plugin/plugin.json"
printf '**Status:** Active plan.\n- [ ] a box\n' > "$r/plugins/p/commands/foo.md"
out=$(run "$r")
check "exec wins over status markers" "Executable prompt content" "$out"
absent "exec file never lands in the status block" "Docs / status-bearing" "$out"
rm -rf "$r"

# --- 9. tracked-modified doc crosses the numstat threshold -------------------
r=$(newrepo)
printf 'small doc\nwith a few\nplain lines\n' > "$r/doc.md"
( cd "$r" && git add -A && git commit -qm init )
i=1; while [[ $i -le 30 ]]; do printf 'appended filler prose line %s\n' "$i" >> "$r/doc.md"; i=$((i+1)); done
out=$(run "$r")
check "30 appended lines on a tracked doc route status-bearing" "Routing: Docs / status-bearing" "$out"
rm -rf "$r"

# --- 10. deleted status doc falls to prose (accepted, documented limit) ------
r=$(newrepo)
printf '**Status:** Active plan.\n- [ ] a box\n' > "$r/plan.md"
( cd "$r" && git add -A && git commit -qm init && rm plan.md )
out=$(run "$r")
check "deleted status doc falls to the prose block" "Routing: Docs / spec" "$out"
absent "deleted status doc is not status-bearing" "Docs / status-bearing" "$out"
rm -rf "$r"

# --- 11. yaml specs never enter the status block -----------------------------
r=$(newrepo)
printf 'openapi: 3.0.0\ninfo:\n  title: t\n' > "$r/openapi.yaml"
out=$(run "$r")
check "openapi spec lands in the prose/spec block" "Routing: Docs / spec" "$out"
absent "openapi spec is not status-bearing" "Docs / status-bearing" "$out"
rm -rf "$r"

# --- 12. no changes ----------------------------------------------------------
r=$(newrepo)
printf 'x\n' > "$r/f.txt"
( cd "$r" && git add -A && git commit -qm init )
out=$(run "$r")
check "clean tree reports no changes" "No changed files detected." "$out"
rm -rf "$r"

# --- 13. exit 0 always, even with routing blocks -----------------------------
r=$(newrepo)
printf 'export const x = 1\n' > "$r/foo.ts"
printf '**Status:** Active.\n' > "$r/plan.md"
( cd "$r" && bash "$SCRIPT" >/dev/null 2>&1 )
code=$?
if [[ "$code" == "0" ]]; then ok "exit 0 on a mixed diff"; else bad "exit 0 on a mixed diff (got $code)"; fi
rm -rf "$r"

# --- 14. --last-commit mode routes status docs and flags the task ------------
r=$(newrepo)
printf '**Status:** Active plan.\n- [ ] a box\n' > "$r/plan.md"
( cd "$r" && git add -A && git commit -qm init )
out=$(run "$r" --last-commit)
check "last-commit mode finds the status doc" "Routing: Docs / status-bearing" "$out"
check "last-commit task carries the flag" "docs-drift.sh\" --last-commit" "$out"
rm -rf "$r"

# --- 15. spec-cmd hints name the reverse mirror check ------------------------
r=$(newrepo)
printf 'package main\n' > "$r/main.go"
out=$(run "$r")
check "Go DRIFT hint names contract-mirror.sh" "contract-mirror.sh reverse check" "$out"
rm -rf "$r"

# --- 15b. plugin resources/*.md is executable prompt content ---------------
r=$(newrepo)
mkdir -p "$r/p/.claude-plugin" "$r/p/resources/nodes"
printf '{}\n' > "$r/p/.claude-plugin/plugin.json"
( cd "$r" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf '# Node\n' > "$r/p/resources/nodes/verify.md"
out=$(run "$r")
check "plugin resources markdown routes as executable prompt" "Routing: Executable prompt content" "$out"
printf 'echo hi\n' > "$r/p/resources/x.sh"
rm -f "$r/p/resources/nodes/verify.md"
out=$(run "$r")
if grep -qF "Routing: Executable prompt content" <<<"$out"; then
  bad "plugin resources shell is not prompt content"
else ok "plugin resources shell is not prompt content"; fi
rm -rf "$r"

# --- 16. deleted plugin: resources/*.md found through the HEAD manifest -----
r=$(newrepo)
mkdir -p "$r/p/.claude-plugin" "$r/p/resources"
printf '{}\n' > "$r/p/.claude-plugin/plugin.json"
printf '# Node\n' > "$r/p/resources/n.md"
( cd "$r" && git add -A && git commit -qm base ) >/dev/null 2>&1
rm -rf "$r/p"
out=$(run "$r")
check "deleted plugin resources markdown is executable prompt" "Routing: Executable prompt content" "$out"
absent "deleted plugin resources markdown is not prose" "Routing: Docs / spec" "$out"
rm -rf "$r"

# --- 17. root-level plugin: resources/*.md beside a root .claude-plugin ------
r=$(newrepo)
mkdir -p "$r/.claude-plugin" "$r/resources"
printf '{}\n' > "$r/.claude-plugin/plugin.json"
( cd "$r" && git add -A && git commit -qm base ) >/dev/null 2>&1
printf '# Node\n' > "$r/resources/n.md"
out=$(run "$r")
check "root plugin resources markdown is executable prompt" "Routing: Executable prompt content" "$out"
rm -rf "$r"

# --- 18. resources/*.md with no plugin manifest is ordinary prose ------------
r=$(newrepo)
mkdir -p "$r/resources"
printf '# Notes\n' > "$r/resources/n.md"
out=$(run "$r")
absent "non-plugin resources markdown is not executable prompt" "Executable prompt content" "$out"
check "non-plugin resources markdown is prose" "Routing: Docs / spec" "$out"
rm -rf "$r"
r=$(newrepo)
mkdir -p "$r/resources"
printf '# Notes\n' > "$r/resources/n.md"
( cd "$r" && git add -A && git commit -qm base && rm resources/n.md ) >/dev/null 2>&1
out=$(run "$r")
absent "deleted non-plugin resources markdown is not executable prompt" "Executable prompt content" "$out"
rm -rf "$r"

# --- 19. the OpenAPI count line pipeline.sh keys RISK=api off ----------------
r=$(newrepo)
mkdir -p "$r/api"
printf 'openapi: 3.0.0\ninfo:\n  title: t\n' > "$r/api/spec.yaml"
out=$(run "$r")
if grep -qxF "  OpenAPI spec             : 1" <<<"$out"; then ok "OpenAPI count line keeps its exact form"
else bad "OpenAPI count line keeps its exact form"; fi
rm -rf "$r"

# --- 20. Notes: effort split, status docs in full, no FRESHNESS agent -------
r=$(newrepo)
printf 'package main\n' > "$r/main.go"
out=$(run "$r")
check "notes give fast-depth finder effort" "effort medium at fast depth and high at deep depth" "$out"
check "notes keep the non-finder effort at high" "challenger, sweep and spec-vs-diff always at high" "$out"
check "notes keep chad-review on its own tiering" "/chad-review: the reviewers below ride its session-" "$out"
check "notes: status-bearing forces deep" "the block forces deep depth" "$out"
check "notes: status finder reads flagged docs in full" "reads each flagged doc IN FULL" "$out"
absent "notes drop the flat ultra-audit effort high" "/ultra-audit runs them on opus at" "$out"
absent "notes drop the LOOKUP-tier FRESHNESS agent" "at LOOKUP tier" "$out"
absent "notes drop the haiku version-lookup line" "Version lookup rides LOOKUP=haiku" "$out"
check "notes: FRESHNESS spawns no agent" "FRESHNESS runs freshness.sh in the parent and spawns no agent" "$out"
rm -rf "$r"
r=$(newrepo)
printf '**Status:** Active plan.\n- [ ] a box\n' > "$r/plan.md"
out=$(run "$r")
check "status block hint says read flagged docs in full" "read each flagged doc IN FULL; run docs-drift.sh" "$out"
rm -rf "$r"

echo
echo "chad-review-route.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
