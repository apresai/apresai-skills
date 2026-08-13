#!/usr/bin/env bash
# pipeline.test.sh: suite for pipeline.sh.
#
# Locks the tier graph: leaf / deps / small / standard / audit floors,
# --full only goes up, and the KEY=value block the parent executes.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pipeline.sh"
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
absent(){
  if grep -qF "$2" <<<"$3"; then
    bad "$1"; printf '       must NOT contain: %s\n' "$2"
  else ok "$1"; fi
}

newrepo(){ d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }
run(){ ( cd "$1" && shift && bash "$SCRIPT" "$@" 2>&1 ); }

# --- 1. trivial docs typo is leaf, no agents, no challenger -------------------
r=$(newrepo)
printf 'A readme.\n\nJust three plain lines.\n' > "$r/README.md"
out=$(run "$r")
check "docs typo is leaf" "TIER=leaf" "$out"
check "docs typo has zero agents" "AGENTS=0" "$out"
check "docs typo lists skim" "NODES=" "$out"
check "docs typo nodes include skim" "skim" "$out"
absent "docs typo does not run challenger" "NODES=" "$(printf '%s\n' "$out" | grep '^NODES=' | grep -F challenger || true)"
check "docs typo skips challenger" "challenger" "$(printf '%s\n' "$out" | grep '^SKIP=')"
rm -rf "$r"

# --- 2. go.mod only is deps ---------------------------------------------------
r=$(newrepo)
printf 'module example.com/x\n\ngo 1.22\n' > "$r/go.mod"
out=$(run "$r")
check "manifest only is deps" "TIER=deps" "$out"
check "deps apply is deps" "APPLY=deps" "$out"
absent "deps does not simplify" "simplify" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 3. tiny Go file is small (leaf is docs/config only) ----------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
check "tiny go is small" "TIER=small" "$out"
check "tiny go lists tests" "tests" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 4. modest one-language Go change is small --------------------------------
r=$(newrepo)
i=1
while [[ $i -le 6 ]]; do
  {
    echo "package p"
    echo "func F$i() {"
    n=1
    while [[ $n -le 20 ]]; do echo "	_ = $n"; n=$((n+1)); done
    echo "}"
  } > "$r/f$i.go"
  i=$((i+1))
done
out=$(run "$r")
check "modest go is small" "TIER=small" "$out"
check "small lists simplify" "simplify" "$(printf '%s\n' "$out" | grep '^NODES=')"
check "small lists impl-review" "impl-review" "$(printf '%s\n' "$out" | grep '^NODES=')"
nodes=$(printf '%s\n' "$out" | grep '^NODES=')
case "$nodes" in
  *docs-apply*impl-review*) ok "small applies docs before impl-review" ;;
  *) bad "small applies docs before impl-review"; printf '       got: %s\n' "$nodes" ;;
esac
absent "small does not list challenger" "challenger" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 5. CLAUDE.md floors to standard ------------------------------------------
r=$(newrepo)
printf '# Project\n\nAlways run tests.\n' > "$r/CLAUDE.md"
out=$(run "$r")
check "exec-md is standard" "TIER=standard" "$out"
check "exec-md floor is recorded" "exec-md" "$(printf '%s\n' "$out" | grep '^FLOORS=')"
absent "exec-md does not simplify" "simplify" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 6. auth.go floors to audit -----------------------------------------------
r=$(newrepo)
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
check "auth path is audit" "TIER=audit" "$out"
check "audit lists challenger" "challenger" "$(printf '%s\n' "$out" | grep '^NODES=')"
check "audit risk is auth" "RISK=auth" "$out"
rm -rf "$r"

# --- 7. --full on a readme is audit -------------------------------------------
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r" --full)
check "--full forces audit" "TIER=audit" "$out"
check "--full records the floor" "FLOORS=full" "$out"
check "--full reason" "REASON=--full" "$out"
rm -rf "$r"

# --- 8. status-bearing doc is not leaf ----------------------------------------
r=$(newrepo)
printf '# Plan\n\n**Status:** Active\n\nThis is the working master plan.\n' > "$r/PLAN.md"
out=$(run "$r")
check "status-bearing is standard" "TIER=standard" "$out"
check "status floor recorded" "status-docs" "$(printf '%s\n' "$out" | grep '^FLOORS=')"
check "status spec present" "SPEC=yes" "$out"
rm -rf "$r"

# --- 9. empty repo is none ----------------------------------------------------
r=$(newrepo)
out=$(run "$r")
check "empty tree is none" "TIER=none" "$out"
check "empty reason" "REASON=nothing to review" "$out"
rm -rf "$r"

# --- 10. required keys always print -------------------------------------------
r=$(newrepo)
printf 'x\n' > "$r/README.md"
out=$(run "$r")
for k in TIER RISK FLOORS AGENTS APPLY SPEC SCOPE_ASK UNTRACKED FILES LINES LANG_BLOCKS NODES SKIP REASON; do
  check "block has $k=" "$k=" "$out"
done
rm -rf "$r"

# --- 11. OpenAPI yaml is audit ------------------------------------------------
r=$(newrepo)
printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 0.0.1\n' > "$r/openapi.yaml"
out=$(run "$r")
check "openapi file is audit" "TIER=audit" "$out"
rm -rf "$r"

# --- 12. audit with a plan runs spec-vs-diff before docs-apply ----------------
r=$(newrepo)
printf '# Plan\n\nDo the login.\n' > "$r/PLAN.md"
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
check "plan plus auth is audit" "TIER=audit" "$out"
check "plan plus auth has SPEC=yes" "SPEC=yes" "$out"
nodes=$(printf '%s\n' "$out" | grep '^NODES=')
check "audit lists spec-vs-diff" "spec-vs-diff" "$nodes"
case "$nodes" in
  *spec-vs-diff*docs-apply*) ok "spec-vs-diff runs before docs-apply" ;;
  *) bad "spec-vs-diff runs before docs-apply"; printf '       got: %s\n' "$nodes" ;;
esac
rm -rf "$r"

# --- 13. go.mod plus a README is still deps -----------------------------------
r=$(newrepo)
printf 'module example.com/x\n\ngo 1.22\n' > "$r/go.mod"
printf 'hello\n' > "$r/README.md"
out=$(run "$r")
check "manifest plus readme is deps" "TIER=deps" "$out"
check "manifest plus readme updates deps" "freshness-update" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 14. shell and terraform count as code ------------------------------------
r=$(newrepo)
printf '#!/bin/sh\necho hi\n' > "$r/deploy.sh"
out=$(run "$r")
check "shell is small not leaf" "TIER=small" "$out"
rm -rf "$r"
r=$(newrepo)
printf 'resource "null_resource" "x" {}\n' > "$r/main.tf"
out=$(run "$r")
check "terraform is small not leaf" "TIER=small" "$out"
rm -rf "$r"

# --- 15. a large test file is not leaf ----------------------------------------
r=$(newrepo)
{
  echo "package p"
  echo "func TestF(t *testing.T) {"
  n=1
  while [[ $n -le 80 ]]; do echo "	_ = $n"; n=$((n+1)); done
  echo "}"
} > "$r/f_test.go"
out=$(run "$r")
check "test-only file is small" "TIER=small" "$out"
check "test-only file runs tests" "tests" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 16. author.go is not an auth floor ---------------------------------------
r=$(newrepo)
printf 'package p\n\nfunc Author() {}\n' > "$r/author.go"
out=$(run "$r")
check "author.go is not audit" "TIER=small" "$out"
absent "author.go is not RISK=auth" "RISK=auth" "$out"
rm -rf "$r"

# --- 17. handler.go alone is not an api floor ---------------------------------
r=$(newrepo)
printf 'package p\n\nfunc Handle() {}\n' > "$r/handler.go"
out=$(run "$r")
check "handler.go is not audit" "TIER=small" "$out"
rm -rf "$r"

# --- 18. AGENTS.md and Claude.md floor to standard ----------------------------
r=$(newrepo)
printf '# Codex\n' > "$r/AGENTS.md"
out=$(run "$r")
check "AGENTS.md is standard" "TIER=standard" "$out"
rm -rf "$r"
r=$(newrepo)
printf '# Claude\n' > "$r/Claude.md"
out=$(run "$r")
check "Claude.md is standard" "TIER=standard" "$out"
rm -rf "$r"

# --- 19. leftover root PLAN.md does not arm spec-vs-diff ----------------------
r=$(newrepo)
printf '# Old plan\n' > "$r/PLAN.md"
( cd "$r" && git add -A && git commit -qm plan ) >/dev/null
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
check "auth without a plan change is audit" "TIER=audit" "$out"
check "untouched PLAN.md is SPEC=no" "SPEC=no" "$out"
absent "untouched PLAN.md does not list spec-vs-diff" "spec-vs-diff" "$(printf '%s\n' "$out" | grep '^NODES=')"
rm -rf "$r"

# --- 20. untracked backup precedes the gate -----------------------------------
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r")
nodes=$(printf '%s\n' "$out" | grep '^NODES=')
case "$nodes" in
  NODES=untracked-backup,gate,*) ok "backup runs before gate when untracked" ;;
  *) bad "backup runs before gate when untracked"; printf '       got: %s\n' "$nodes" ;;
esac
rm -rf "$r"

# --- 21. SKIP keeps the last token --------------------------------------------
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r")
skip=$(printf '%s\n' "$out" | grep '^SKIP=')
check "leaf SKIP still lists score" "score" "$skip"
rm -rf "$r"

# --- 22. two-language tiny diff is not leaf -----------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
printf 'export const x = 1\n' > "$r/app.ts"
out=$(run "$r")
check "two-language tiny is not leaf" "TIER=" "$out"
absent "two-language tiny is not leaf" "TIER=leaf" "$out"
rm -rf "$r"

# --- 23. APPLY omits simplify when NODES omitted it ---------------------------
r=$(newrepo)
printf '# Project\n' > "$r/CLAUDE.md"
out=$(run "$r")
absent "exec-md APPLY has no simplify" "simplify" "$(printf '%s\n' "$out" | grep '^APPLY=')"
rm -rf "$r"

echo "pipeline.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
