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

newrepo(){ d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }

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

echo "docs-apply.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
