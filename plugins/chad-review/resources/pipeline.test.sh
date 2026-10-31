#!/usr/bin/env bash
# pipeline.test.sh: suite for pipeline.sh.
#
# Locks the no-tier contract (chad-review 3.0.0): every diff, whatever its
# shape, gets the full review graph (impl-review, challenger, verify, sweep).
# The only omitted nodes are input-driven: spec-vs-diff without a changed
# PLAN.md, simplify without code or with executable prompt content, and
# untracked-backup without untracked files. --full is a no-op.
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
nodes_of(){ printf '%s\n' "$1" | grep '^NODES=' || true; }
skip_of(){ printf '%s\n' "$1" | grep '^SKIP=' || true; }

# Every review node must be present on every non-empty diff.
full_review(){
  local label="$1" out="$2" n
  n=$(nodes_of "$out")
  check "$label: MODE=full" "MODE=full" "$out"
  absent "$label: no TIER key" "TIER=" "$out"
  for node in gate docs-drift contract-mirror tests freshness-audit freshness-update docs-apply skim impl-review challenger verify sweep receipt; do
    check "$label: runs $node" ",$node," ",${n#NODES=},"
  done
  absent "$label: no score node" "score" "$n"
}

# --- 1. trivial docs typo gets the full review --------------------------------
r=$(newrepo)
printf 'A readme.\n\nJust three plain lines.\n' > "$r/README.md"
out=$(run "$r")
full_review "docs typo" "$out"
absent "docs typo does not simplify" "simplify" "$(nodes_of "$out")"
check "docs typo skips simplify" "simplify" "$(skip_of "$out")"
check "docs typo has at least 3 agents" "AGENTS=3" "$out"
rm -rf "$r"

# --- 2. go.mod only gets the full review --------------------------------------
r=$(newrepo)
printf 'module example.com/x\n\ngo 1.22\n' > "$r/go.mod"
out=$(run "$r")
full_review "manifest only" "$out"
check "manifest apply includes deps" "deps" "$(printf '%s\n' "$out" | grep '^APPLY=')"
rm -rf "$r"

# --- 3. tiny Go file gets the full review and simplify ------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
full_review "tiny go" "$out"
check "tiny go simplifies" "simplify" "$(nodes_of "$out")"
rm -rf "$r"

# --- 4. CLAUDE.md is reviewed, never simplified -------------------------------
r=$(newrepo)
printf '# Project\n\nAlways run tests.\n' > "$r/CLAUDE.md"
out=$(run "$r")
full_review "exec-md" "$out"
absent "exec-md does not simplify" "simplify" "$(nodes_of "$out")"
absent "exec-md APPLY has no simplify" "simplify" "$(printf '%s\n' "$out" | grep '^APPLY=')"
rm -rf "$r"

# --- 5. auth.go records risk, same node set -----------------------------------
r=$(newrepo)
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
full_review "auth" "$out"
check "auth risk recorded" "RISK=auth" "$out"
rm -rf "$r"

# --- 6. --full is accepted and changes nothing --------------------------------
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
a=$(run "$r")
b=$(run "$r" --full)
if [[ "$a" == "$b" ]]; then ok "--full is a no-op"; else bad "--full is a no-op"; fi
rm -rf "$r"

# --- 7. bad flag is a usage error ---------------------------------------------
r=$(newrepo)
( cd "$r" && bash "$SCRIPT" --bogus >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "unknown flag exits 2"; else bad "unknown flag exits 2 (got $rc)"; fi
rm -rf "$r"

# --- 8. empty repo is none ----------------------------------------------------
r=$(newrepo)
out=$(run "$r")
check "empty tree is none" "MODE=none" "$out"
check "empty tree has no nodes" "NODES=" "$out"
check "empty tree reason" "REASON=nothing to review" "$out"
rm -rf "$r"

# --- 9. not a git repo is none ------------------------------------------------
d=$(mktemp -d)
out=$( cd "$d" && bash "$SCRIPT" 2>&1 )
check "non-repo is none" "MODE=none" "$out"
check "non-repo reason" "REASON=not a git repository" "$out"
rm -rf "$d"

# --- 10. required keys always print -------------------------------------------
r=$(newrepo)
printf 'x\n' > "$r/README.md"
out=$(run "$r")
for k in MODE RISK AGENTS APPLY SPEC SCOPE_ASK UNTRACKED FILES LINES LANG_BLOCKS NODES SKIP REASON; do
  check "key $k prints" "$k=" "$out"
done
rm -rf "$r"

# --- 11. OpenAPI yaml records api risk ----------------------------------------
r=$(newrepo)
printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 0.0.1\n' > "$r/openapi.yaml"
out=$(run "$r")
full_review "openapi" "$out"
check "openapi risk recorded" "api" "$(printf '%s\n' "$out" | grep '^RISK=')"
rm -rf "$r"

# --- 12. a changed plan runs spec-vs-diff before docs-apply -------------------
r=$(newrepo)
printf '# Plan\n\nDo the login.\n' > "$r/PLAN.md"
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
check "plan arms SPEC" "SPEC=yes" "$out"
nodes=$(nodes_of "$out")
case "$nodes" in
  *spec-vs-diff*docs-apply*) ok "spec-vs-diff runs before docs-apply" ;;
  *) bad "spec-vs-diff runs before docs-apply"; printf '       got: %s\n' "$nodes" ;;
esac
rm -rf "$r"

# --- 13. a leftover committed PLAN.md does not arm spec-vs-diff ---------------
r=$(newrepo)
printf '# Old plan\n' > "$r/PLAN.md"
( cd "$r" && git add -A && git commit -qm plan ) >/dev/null
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
out=$(run "$r")
check "untouched PLAN.md is SPEC=no" "SPEC=no" "$out"
absent "untouched PLAN.md does not list spec-vs-diff" "spec-vs-diff" "$(nodes_of "$out")"
check "untouched PLAN.md skips spec-vs-diff" "spec-vs-diff" "$(skip_of "$out")"
rm -rf "$r"

# --- 14. node order: backup, gate, applies, then reviews ----------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
nodes=$(nodes_of "$out")
case "$nodes" in
  NODES=untracked-backup,gate,*) ok "backup runs before gate when untracked" ;;
  *) bad "backup runs before gate when untracked"; printf '       got: %s\n' "$nodes" ;;
esac
case "$nodes" in
  *simplify*docs-apply*impl-review*challenger*verify*sweep*receipt) ok "apply before review, receipt last" ;;
  *) bad "apply before review, receipt last"; printf '       got: %s\n' "$nodes" ;;
esac
rm -rf "$r"

# --- 15. no untracked files skips the backup ----------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
( cd "$r" && git add -A && git commit -qm base ) >/dev/null
printf 'package p\n\nfunc F() { _ = 1 }\n' > "$r/f.go"
out=$(run "$r")
absent "tracked-only diff has no backup node" "untracked-backup" "$(nodes_of "$out")"
check "tracked-only diff skips backup" "untracked-backup" "$(skip_of "$out")"
full_review "tracked-only" "$out"
rm -rf "$r"

# --- 16. two-language diff counts both blocks ---------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
printf 'export const x = 1\n' > "$r/app.ts"
out=$(run "$r")
full_review "two-language" "$out"
check "two-language has 4 agents" "AGENTS=4" "$out"
rm -rf "$r"

# --- 17. last-commit mode reviews HEAD ----------------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
( cd "$r" && git add -A && git commit -qm one ) >/dev/null
out=$(run "$r" --last-commit)
full_review "last-commit" "$out"
rm -rf "$r"

# --- 18. config-only gets the full review -------------------------------------
r=$(newrepo)
printf 'node_modules/\n' > "$r/.gitignore"
out=$(run "$r")
full_review "config-only" "$out"
rm -rf "$r"

echo "pipeline.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
