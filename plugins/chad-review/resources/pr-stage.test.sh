#!/usr/bin/env bash
# pr-stage.test.sh: suite for pr-stage.sh.
#
# Locks the full-PR staging contract: committed branch work, uncommitted
# edits, and untracked files all appear as working-tree changes in the
# staged worktree; export isolates later edits; remove cleans up.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-stage.sh"
PIPE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pipeline.sh"
pass=0; fail=0
TMPS=()
cleanup(){ local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ if grep -qF "$2" <<<"$3"; then ok "$1"; else bad "$1"; printf '       wanted: %s\n       got: %s\n' "$2" "$3"; fi; }

newrepo(){
  local d; d=$(mktemp -d); TMPS+=("$d")
  ( cd "$d" && git init -q -b main . && printf 'base\n' > base.txt && git add -A && git commit -qm base \
    && git checkout -q -b feat ) >/dev/null 2>&1
  echo "$d"
}
val(){ printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# --- 1. two commits plus a dirty edit plus an untracked file all stage --------
r=$(newrepo)
( cd "$r" && printf 'package p\n\nfunc A() {}\n' > a.go && git add -A && git commit -qm one \
  && printf 'package p\n\nfunc B() {}\n' > b.go && git add -A && git commit -qm two \
  && printf 'base\nedited\n' > base.txt && printf 'new\n' > new.md ) >/dev/null
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>&1 )
dir=$(val DIR "$out")
TMPS+=("$dir")
check "stage prints DIR" "DIR=" "$out"
check "stage counts four changed paths" "FILES=4" "$out"
st=$(git -C "$dir" status --porcelain)
check "first commit's file is a change" "a.go" "$st"
check "second commit's file is a change" "b.go" "$st"
check "uncommitted edit is a change" "base.txt" "$st"
check "untracked file is a change" "new.md" "$st"
if [[ -z "$(git -C "$dir" diff --cached --name-only)" ]]; then ok "nothing left staged in the index"; else bad "nothing left staged in the index"; fi
pl=$( cd "$dir" && bash "$PIPE" 2>&1 )
check "pipeline sees all four files" "FILES=4" "$pl"

# --- 2. export isolates edits made after staging ------------------------------
printf 'package p\n\nfunc A() { _ = 1 }\n' > "$dir/a.go"
patch=$(bash "$SCRIPT" export "$dir")
check "export carries the later edit" "func A() { _ = 1 }" "$patch"
if grep -qF "func B()" <<<"$patch"; then bad "export omits the staged content"; else ok "export omits the staged content"; fi
( cd "$r" && git apply --check - <<<"$patch" ) && ok "export patch applies to the real branch" || bad "export patch applies to the real branch"

# --- 3. remove deletes the worktree -------------------------------------------
bash "$SCRIPT" remove "$dir"
if [[ ! -d "$dir" ]]; then ok "remove deletes the staged worktree"; else bad "remove deletes the staged worktree"; fi

# --- 4. nothing to stage exits 1 ----------------------------------------------
r=$(newrepo)
( cd "$r" && bash "$SCRIPT" stage --base main >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 1 ]]; then ok "nothing to stage exits 1"; else bad "nothing to stage exits 1 (got $rc)"; fi

# --- 5. usage errors exit 2 ---------------------------------------------------
( bash "$SCRIPT" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "no subcommand exits 2"; else bad "no subcommand exits 2 (got $rc)"; fi
( bash "$SCRIPT" export /nonexistent >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "export on a missing dir exits 2"; else bad "export on a missing dir exits 2 (got $rc)"; fi
d=$(mktemp -d); TMPS+=("$d")
( cd "$d" && git init -q . ) >/dev/null
( bash "$SCRIPT" remove "$d" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 && -d "$d" ]]; then ok "remove refuses a non-staged dir"; else bad "remove refuses a non-staged dir (got $rc)"; fi

echo "pr-stage.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
