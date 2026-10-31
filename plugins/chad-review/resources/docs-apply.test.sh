#!/usr/bin/env bash
# docs-apply.test.sh: STALE applies, CONTRA does not, exec-md is skipped.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docs-apply.sh"
pass=0; fail=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){
  if grep -qF "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}

newrepo(){ local d; d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }

# Authority BUILD_NUMBER 152, live doc still says 117 or later.
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Device\n\nInstall build 117 or later.\n' > "$r/checklist.md"
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
check "applies the stale floor" "APPLIED" "$out"
if grep -q 'Install build 152 or later' "$r/checklist.md"; then
  ok "rewrote the live floor to the authority value"
else
  bad "rewrote the live floor to the authority value"
  printf '       file:\n%s\n' "$(cat "$r/checklist.md")"
fi

# CONTRA is not rewritten.
r=$(newrepo)
printf '# Plan\n\n**Status:** Active\n\n# Historical\n\nThis is the historical execution record.\n' > "$r/PLAN.md"
before=$(cat "$r/PLAN.md")
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
after=$(cat "$r/PLAN.md")
check "contra is reported" "REPORT" "$out"
if [[ "$before" == "$after" ]]; then ok "contra file is unchanged"; else bad "contra file is unchanged"; fi

# exec-md STALE is skipped (CLAUDE.md).
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Notes\n\nUse build 117 or later.\n' > "$r/CLAUDE.md"
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
check "exec-md stale is skipped" "SKIP" "$out"
if grep -q 'build 117' "$r/CLAUDE.md"; then ok "CLAUDE.md was not rewritten"; else bad "CLAUDE.md was not rewritten"; fi

r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Notes\n\nUse build 117 or later.\n' > "$r/AGENTS.md"
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
if grep -q 'build 117' "$r/AGENTS.md"; then ok "AGENTS.md was not rewritten"; else bad "AGENTS.md was not rewritten"; fi

r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Notes\n\nUse build 117 or later.\n' > "$r/Claude.md"
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
if grep -q 'build 117' "$r/Claude.md"; then ok "Claude.md was not rewritten"; else bad "Claude.md was not rewritten"; fi

# A plugin's resources/*.md is executable prompt content: root and nested
# copies are skipped, while a plain doc in the same repo is still applied, so
# a pattern that skips too much fails here as well as one that skips too little.
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
mkdir -p "$r/resources" "$r/p/resources/nodes"
printf '# Node\n\nUse build 117 or later.\n' > "$r/resources/n.md"
printf '# Node\n\nUse build 117 or later.\n' > "$r/p/resources/nodes/v.md"
printf '# Guide\n\nUse build 117 or later.\n' > "$r/resources.md"
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
check "root resources md stale is skipped" "SKIP	exec-md	resources/n.md:3" "$out"
check "nested resources md stale is skipped" "SKIP	exec-md	p/resources/nodes/v.md:3" "$out"
if grep -q 'build 117' "$r/resources/n.md"; then ok "resources/n.md was not rewritten"; else bad "resources/n.md was not rewritten"; fi
if grep -q 'build 117' "$r/p/resources/nodes/v.md"; then ok "p/resources/nodes/v.md was not rewritten"; else bad "p/resources/nodes/v.md was not rewritten"; fi
check "control doc next to them is applied" "APPLIED	resources.md:3" "$out"
if grep -q 'build 152' "$r/resources.md"; then ok "resources.md was rewritten"; else bad "resources.md was rewritten"; fi
rm -rf "$r"

# The `--` form reaches docs whose change is already committed (ultra-audit
# runs docs-apply in the real worktree after fix commits). Without it, a clean
# tree has nothing to apply.
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Guide\n\nUse build 117 or later.\n' > "$r/guide.md"
( cd "$r" && git add -A && git commit -qm docs ) >/dev/null 2>&1
out=$(cd "$r" && bash "$SCRIPT" 2>&1)
if grep -q 'build 117' "$r/guide.md"; then ok "clean tree: committed doc untouched without --"; else bad "clean tree: committed doc untouched without --"; fi
out=$(cd "$r" && bash "$SCRIPT" -- guide.md 2>&1)
check "-- form applies a committed doc" "APPLIED	guide.md:3" "$out"
if grep -q 'build 152' "$r/guide.md"; then ok "committed doc rewritten via --"; else bad "committed doc rewritten via --"; fi
( cd "$r" && bash "$SCRIPT" -- >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "bare -- is usage"; else bad "bare -- is usage (got $rc)"; fi
rm -rf "$r"

echo "docs-apply.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
