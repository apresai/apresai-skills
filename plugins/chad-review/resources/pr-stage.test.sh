#!/usr/bin/env bash
# pr-stage.test.sh: suite for pr-stage.sh.
#
# Locks the full-PR staging contract: committed branch work, uncommitted
# edits, and untracked files all appear as working-tree changes in the
# staged worktree; base resolution matches receipt.sh; odd names, symlinks,
# nested repos, ignored-forced files and submodule bumps are handled or
# reported; user diff/apply config cannot break staging; a failed stage
# cleans up and exits 2; check compares real and staged content; remove
# cleans up.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-stage.sh"
RECEIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/receipt.sh"
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
# receipt_base <repo>: the base_ref receipt.sh resolves there (emits a NO-GO
# receipt into that repo's own store, which the temp repo discards).
receipt_base(){ local f; f=$( cd "$1" && bash "$RECEIPT" emit --verdict NO-GO 2>/dev/null | head -1 )
  [[ -n "$f" && -f "$f" ]] && sed -n 's/.*"base_ref": "\(.*\)",/\1/p' "$f"; }
same_base(){ # same_base <desc> <repo> <stage output>
  local want got; want=$(val BASE "$3"); got=$(receipt_base "$2")
  if [[ -n "$want" && "$want" == "$got" ]]; then ok "$1"; else bad "$1 (pr-stage '$want', receipt.sh '$got')"; fi; }

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
check "stage prints BASE" "BASE=main" "$out"
check "stage prints the real branch" "BRANCH=feat" "$out"
check "stage prints IGNORED_FORCED" "IGNORED_FORCED=0" "$out"
check "stage prints SUBMODULES" "SUBMODULES=0" "$out"
case "$dir" in /*) ok "DIR is absolute" ;; *) bad "DIR is absolute ($dir)" ;; esac
st=$(git -C "$dir" status --porcelain)
check "first commit's file is a change" "a.go" "$st"
check "second commit's file is a change" "b.go" "$st"
check "uncommitted edit is a change" "base.txt" "$st"
check "untracked file is a change" "new.md" "$st"
if [[ -z "$(git -C "$dir" diff --cached --name-only)" ]]; then ok "nothing left staged in the index"; else bad "nothing left staged in the index"; fi
pl=$( cd "$dir" && bash "$PIPE" 2>&1 )
check "pipeline sees all four files" "FILES=4" "$pl"

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
( bash "$SCRIPT" export "$r" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "the retired export subcommand is usage (exit 2)"; else bad "the retired export subcommand is usage (exit 2) (got $rc)"; fi
d=$(mktemp -d); TMPS+=("$d")
( cd "$d" && git init -q . ) >/dev/null
( bash "$SCRIPT" remove "$d" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 && -d "$d" ]]; then ok "remove refuses a non-staged dir"; else bad "remove refuses a non-staged dir (got $rc)"; fi

# --- 6. default base resolves like receipt.sh resolve_base --------------------
up=$(mktemp -d); TMPS+=("$up")
( cd "$up" && git init -q -b main . && printf 'base\n' > base.txt && git add -A && git commit -qm base \
  && git checkout -q -b develop && printf 'dev\n' > dev.txt && git add -A && git commit -qm dev \
  && git checkout -q main ) >/dev/null 2>&1
cl=$(mktemp -d); TMPS+=("$cl"); rmdir "$cl"
git clone -q "$up" "$cl" >/dev/null 2>&1
( cd "$cl" && git remote set-head origin develop && git checkout -q -b feat origin/develop \
  && printf 'f\n' > f.txt && git add -A && git commit -qm f ) >/dev/null 2>&1
out=$( cd "$cl" && bash "$SCRIPT" stage 2>/dev/null ); dir=$(val DIR "$out"); TMPS+=("$dir")
check "default base follows origin/HEAD" "BASE=origin/develop" "$out"
same_base "receipt.sh resolves the same origin/HEAD base" "$cl" "$out"
check "origin/HEAD base stages only the branch's own file" "FILES=1" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"
( cd "$cl" && git remote set-head origin -d ) >/dev/null 2>&1
out=$( cd "$cl" && bash "$SCRIPT" stage 2>/dev/null ); dir=$(val DIR "$out"); TMPS+=("$dir")
check "without origin/HEAD, origin/main comes next" "BASE=origin/main" "$out"
same_base "receipt.sh resolves the same origin/main base" "$cl" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"
m=$(mktemp -d); TMPS+=("$m")
( cd "$m" && git init -q -b master . && printf 'base\n' > base.txt && git add -A && git commit -qm base \
  && git checkout -q -b feat && printf 'x\n' > x.txt && git add -A && git commit -qm x ) >/dev/null 2>&1
out=$( cd "$m" && bash "$SCRIPT" stage 2>&1 ); rc=$?; dir=$(val DIR "$out"); TMPS+=("$dir")
if [[ "$rc" -eq 0 ]]; then ok "master-default repo stages (rc 0)"; else bad "master-default repo stages (rc $rc): $out"; fi
check "master-default repo resolves master" "BASE=master" "$out"
same_base "receipt.sh resolves the same master base" "$m" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"
( cd "$m" && bash "$SCRIPT" stage --base nosuch >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "unknown base exits 2"; else bad "unknown base exits 2 (got $rc)"; fi

# --- 7. non-ASCII names, dangling symlinks, nested repos ----------------------
r=$(newrepo)
( cd "$r" && printf 'c\n' > "café.txt" && ln -s nowhere link && mkdir sub && cd sub && git init -q . \
  && printf 's\n' > s.txt && git add -A && git commit -qm s ) >/dev/null 2>&1
err=$(mktemp); TMPS+=("$err")
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>"$err" ); rc=$?; dir=$(val DIR "$out"); TMPS+=("$dir")
if [[ "$rc" -eq 0 ]]; then ok "odd untracked entries still stage (rc 0)"; else bad "odd untracked entries still stage (rc $rc): $(cat "$err")"; fi
if [[ -f "$dir/café.txt" ]]; then ok "non-ASCII untracked name is copied"; else bad "non-ASCII untracked name is copied"; fi
if [[ -L "$dir/link" && "$(readlink "$dir/link")" == nowhere ]]; then ok "dangling symlink is copied as a symlink"; else bad "dangling symlink is copied as a symlink"; fi
if [[ ! -e "$dir/sub" ]]; then ok "nested repo is skipped"; else bad "nested repo is skipped"; fi
check "nested repo skip is noted on stderr" "skipped nested repository sub" "$(cat "$err")"
( cd "$r" && bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check: nested repo, symlink and non-ASCII name still match"; else bad "check: nested repo, symlink and non-ASCII name still match (rc $rc)"; fi
check "odd entries count as two files" "FILES=2" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 8. branch files force-added under ignored paths --------------------------
r=$(newrepo)
( cd "$r" && printf 'build/\n' > .gitignore && git add .gitignore && git commit -qm ign \
  && mkdir build && printf 'gen\n' > build/gen.txt && git add -f build/gen.txt && git commit -qm gen \
  && printf 'y\n' > y.txt ) >/dev/null 2>&1
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>"$err" ); dir=$(val DIR "$out"); TMPS+=("$dir")
check "ignored-forced file is counted" "IGNORED_FORCED=1" "$out"
check "ignored-forced file is listed on stderr" "build/gen.txt" "$(cat "$err")"
check "ignored-forced file shows in staged status" "build/gen.txt" "$(git -C "$dir" status --porcelain -uall)"
check "ignored-forced file counts toward FILES" "FILES=3" "$out"
if [[ -z "$(git -C "$dir" diff --cached --name-only)" ]]; then ok "intent-to-add leaves nothing staged"; else bad "intent-to-add leaves nothing staged"; fi
pl=$( cd "$dir" && bash "$PIPE" 2>&1 )
check "pipeline sees the ignored-forced file" "FILES=3" "$pl"
( bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check: ignored-forced file matches its intent-to-add copy"; else bad "check: ignored-forced file matches its intent-to-add copy (rc $rc)"; fi
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 9. submodule pointer bump is reported, not dropped -----------------------
sm=$(mktemp -d); TMPS+=("$sm")
( cd "$sm" && git init -q -b main . && printf '1\n' > f && git add f && git commit -qm 1 ) >/dev/null 2>&1
r=$(newrepo)
( cd "$r" && git -c protocol.file.allow=always submodule add -q "$sm" sub && git commit -qm sub \
  && git checkout -q main && git merge -q --ff-only feat && git checkout -q feat \
  && ( cd "$sm" && printf '2\n' > f && git commit -qam 2 ) \
  && ( cd sub && git -c protocol.file.allow=always pull -q origin main ) && git add sub && git commit -qm bump ) >/dev/null 2>&1
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>"$err" ); rc=$?; dir=$(val DIR "$out"); TMPS+=("$dir")
if [[ "$rc" -eq 0 ]]; then ok "submodule-only change is not 'nothing to stage'"; else bad "submodule-only change is not 'nothing to stage' (rc $rc)"; fi
check "submodule bump is counted" "SUBMODULES=1" "$out"
( bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check: submodule pointer difference is not compared"; else bad "check: submodule pointer difference is not compared (rc $rc)"; fi
check "submodule bump is listed on stderr" "submodule pointer change" "$(cat "$err")"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 10. FILES counts files inside new directories ----------------------------
r=$(newrepo)
( cd "$r" && mkdir -p pkg/x && printf 'a\n' > pkg/x/a.go && printf 'b\n' > pkg/x/b.go && printf 'c\n' > pkg/c.go \
  && printf 'base\nedit\n' > base.txt && git add -A && git commit -qm pkg ) >/dev/null 2>&1
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>&1 ); dir=$(val DIR "$out"); TMPS+=("$dir")
check "FILES counts every file in new directories" "FILES=4" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 11. relative TMPDIR ------------------------------------------------------
r=$(newrepo)
( cd "$r" && printf 'r\n' > r.txt && git add -A && git commit -qm r ) >/dev/null 2>&1
out=$( cd "$r" && TMPDIR=reltmp bash "$SCRIPT" stage --base main 2>&1 ); rc=$?; dir=$(val DIR "$out")
if [[ "$rc" -eq 0 ]]; then ok "relative TMPDIR stages (rc 0)"; else bad "relative TMPDIR stages (rc $rc): $out"; fi
case "$dir" in /*) ok "relative TMPDIR still gives an absolute DIR" ;; *) bad "relative TMPDIR still gives an absolute DIR ($dir)" ;; esac
check "temp files under a relative TMPDIR are not staged" "FILES=1" "$out"
( cd "$r" && TMPDIR=reltmp bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check ignores an in-repo temp root"; else bad "check ignores an in-repo temp root (rc $rc)"; fi
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 12. user diff/apply config cannot break staging --------------------------
r=$(newrepo)
( cd "$r" && printf 'trailing   \n' > ws.txt && git add -A && git commit -qm ws ) >/dev/null 2>&1
uc=$(mktemp); TMPS+=("$uc")
printf '[diff]\n\tnoprefix = true\n\tmnemonicPrefix = true\n[apply]\n\twhitespace = error\n[color]\n\tdiff = always\n\tui = always\n[core]\n\tquotepath = true\n' > "$uc"
out=$( cd "$r" && GIT_CONFIG_GLOBAL="$uc" bash "$SCRIPT" stage --base main 2>&1 ); rc=$?; dir=$(val DIR "$out"); TMPS+=("$dir")
if [[ "$rc" -eq 0 ]]; then ok "noprefix/whitespace=error/color config still stages"; else bad "noprefix/whitespace=error/color config still stages (rc $rc): $out"; fi
if [[ -f "$dir/ws.txt" ]]; then ok "content with trailing whitespace is applied"; else bad "content with trailing whitespace is applied"; fi
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

# --- 13. a failed stage cleans up and exits 2 ---------------------------------
r=$(newrepo)
( cd "$r" && printf 'u\n' > u.txt ) >/dev/null
shim=$(mktemp -d); TMPS+=("$shim")
printf '#!/bin/sh\nexit 1\n' > "$shim/cp"; chmod +x "$shim/cp"
td=$(mktemp -d); TMPS+=("$td")
( cd "$r" && PATH="$shim:$PATH" TMPDIR="$td" bash "$SCRIPT" stage --base main >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "failed stage exits 2, not 1"; else bad "failed stage exits 2, not 1 (got $rc)"; fi
if git -C "$r" worktree list | grep -q pr-stage; then bad "failed stage leaves no registered worktree"; else ok "failed stage leaves no registered worktree"; fi
if [[ -z "$(ls -A "$td")" ]]; then ok "failed stage leaves no temp files"; else bad "failed stage leaves no temp files: $(ls -A "$td")"; fi
e=$(mktemp -d); TMPS+=("$e")
( cd "$e" && git init -q . && bash "$SCRIPT" stage >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "repo without commits exits 2"; else bad "repo without commits exits 2 (got $rc)"; fi

# --- 14. check compares real and staged content -------------------------------
r=$(newrepo)
( cd "$r" && printf 'node_modules/\n' > .gitignore && printf 'k\n' > k.txt && git add -A && git commit -qm k \
  && printf 'base\ndirty\n' > base.txt ) >/dev/null 2>&1
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>/dev/null ); dir=$(val DIR "$out"); TMPS+=("$dir")
mkdir -p "$r/node_modules/x"; printf 'dep\n' > "$r/node_modules/x/i.js"
idx_before=$(cksum < "$r/.git/index")
( bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check: unchanged real tree matches (ignored files do not count)"; else bad "check: unchanged real tree matches (rc $rc)"; fi
if [[ "$(cksum < "$r/.git/index")" == "$idx_before" ]]; then ok "check leaves the real index untouched"; else bad "check leaves the real index untouched"; fi
printf 'k2\n' > "$r/k.txt"
co=$( bash "$SCRIPT" check "$dir" 2>/dev/null ); rc=$?
if [[ "$rc" -eq 1 ]]; then ok "check: a real-tree edit differs (rc 1)"; else bad "check: a real-tree edit differs (rc $rc)"; fi
check "check prints the differing path" "k.txt" "$co"
printf 'k\n' > "$r/k.txt"; printf 'n\n' > "$r/late.txt"
co=$( bash "$SCRIPT" check "$dir" 2>/dev/null ); rc=$?
if [[ "$rc" -eq 1 ]]; then ok "check: a new untracked real file differs"; else bad "check: a new untracked real file differs (rc $rc)"; fi
check "check names the new file" "late.txt" "$co"
rm "$r/late.txt"; printf 's\n' > "$dir/stray.txt"
co=$( bash "$SCRIPT" check "$dir" 2>/dev/null ); rc=$?
if [[ "$rc" -eq 1 ]]; then ok "check: a stray file in the staged dir differs"; else bad "check: a stray file in the staged dir differs (rc $rc)"; fi
rm "$dir/stray.txt"
( bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 0 ]]; then ok "check: matches again once restored"; else bad "check: matches again once restored (rc $rc)"; fi
( bash "$SCRIPT" check /nonexistent >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "check on a missing dir exits 2"; else bad "check on a missing dir exits 2 (got $rc)"; fi

# --- 15. a partially staged dir: check refuses, remove still works -------------
printf 'pending\n' > "$(git -C "$dir" rev-parse --absolute-git-dir)/pr-stage-tree"
( bash "$SCRIPT" check "$dir" >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "check refuses an unfinished stage"; else bad "check refuses an unfinished stage (got $rc)"; fi
bash "$SCRIPT" remove "$dir" >/dev/null 2>&1
if [[ ! -d "$dir" ]] && ! git -C "$r" worktree list | grep -q pr-stage; then ok "remove clears a partially staged dir"; else bad "remove clears a partially staged dir"; fi

# --- 16. detached HEAD reports BRANCH=detached --------------------------------
r=$(newrepo)
( cd "$r" && printf 'd\n' > d.txt && git add -A && git commit -qm d && git checkout -q --detach ) >/dev/null 2>&1
out=$( cd "$r" && bash "$SCRIPT" stage --base main 2>/dev/null ); dir=$(val DIR "$out"); TMPS+=("$dir")
check "detached HEAD prints BRANCH=detached" "BRANCH=detached" "$out"
[[ -n "$dir" ]] && bash "$SCRIPT" remove "$dir"

echo "pr-stage.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
