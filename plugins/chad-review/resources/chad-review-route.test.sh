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
# behavior (Go to feature-dev:code-reviewer, exec markdown to general-purpose,
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
  if grep -qF "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}
absent(){ # absent <desc> <substring-that-must-not-appear> <actual>
  if grep -qF "$2" <<<"$3"; then
    bad "$1"; printf '       must NOT contain: %s\n' "$2"
  else ok "$1"; fi
}

newrepo(){ d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }
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
check "mixed diff still routes generic TS" "typescript-pro" "$out"
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

# --- 7. regression: Go routes to feature-dev:code-reviewer -------------------
r=$(newrepo)
printf 'package main\n' > "$r/main.go"
out=$(run "$r")
check "Go routes to its specialist" "feature-dev:code-reviewer" "$out"
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

echo
echo "chad-review-route.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
