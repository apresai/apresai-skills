#!/usr/bin/env bash
# untracked-guard.test.sh — run: bash untracked-guard.test.sh
#
# WHY THIS EXISTS
# The untracked guard went through four review rounds and each of the first
# three shipped a defect: shell state that did not survive between two separate
# Bash calls, quoting handled inconsistently in two places, and a restore that
# overwrote live files because "absent from `git ls-files --others`" was
# conflated with "gone from disk" (staging a file with `git add` was enough to
# trigger it). Every one of those is cheap to catch with a fixture and expensive
# to catch by reading.
#
# Each case runs `backup` and `verify` as SEPARATE bash invocations, because that
# is the way the skill invokes them and the way three of the bugs hid.
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/untracked-guard.sh"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

newrepo() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q .
  echo tracked > "$d/tracked.txt"
  git -C "$d" add -A >/dev/null; git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
  echo "$d"
}

echo "untracked-guard.sh test suite"

# --- 1. round trip across separate invocations, hostile filenames -------------
r=$(newrepo); mkdir -p "$r/a/b/c"
printf 'x\n' > "$r/a/b/c/deep.go"
printf 'x\n' > "$r/has space.md"
printf 'x\n' > "$r/ünïcode.md"
printf 'x\n' > "$r/-dash.txt"
ln -s tracked.txt "$r/link"
ln -s /nonexistent "$r/dangling"
echo "secret" > "$r/.env"; echo ".env" > "$r/.gitignore"
git -C "$r" add .gitignore >/dev/null; git -C "$r" -c user.email=t@t -c user.name=t commit -qm gi
( cd "$r" && bash "$GUARD" backup >/dev/null 2>&1 ); check "backup exits 0" "$?" "0"
bk=$( cd "$r" && bash "$GUARD" backup 2>/dev/null )
[[ -f "$bk/a/b/c/deep.go" ]] && ok "nested path backed up" || bad "nested path backed up"
[[ -f "$bk/has space.md" ]] && ok "space in name" || bad "space in name"
[[ -f "$bk/ünïcode.md" ]] && ok "non-ASCII name" || bad "non-ASCII name"
[[ -f "$bk/-dash.txt" ]] && ok "leading-dash name" || bad "leading-dash name"
[[ -L "$bk/link" ]] && ok "symlink kept as symlink" || bad "symlink kept as symlink"
[[ -L "$bk/dangling" ]] && ok "dangling symlink backed up" || bad "dangling symlink backed up"
[[ -e "$bk/.env" ]] && bad "gitignored file MUST NOT be backed up" || ok "gitignored file excluded"

# --- 2. the incident: files destroyed, then restored --------------------------
( cd "$r" && git clean -qfd )
( cd "$r" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify exits 1 when files vanished" "$?" "1"
( cd "$r" && bash "$GUARD" verify --restore >/dev/null 2>&1 )
[[ -f "$r/a/b/c/deep.go" && -f "$r/has space.md" && -f "$r/ünïcode.md" && -f "$r/-dash.txt" ]] \
  && ok "all restored" || bad "all restored"
[[ -L "$r/link" ]] && ok "restored symlink is still a symlink" || bad "restored symlink is still a symlink"
( cd "$r" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify clean after restore" "$?" "0"

# --- 3. THE BLOCKER: staging must not look like deletion ---------------------
r2=$(newrepo)
printf 'original\n' > "$r2/note.txt"
( cd "$r2" && bash "$GUARD" backup >/dev/null 2>&1 )
printf 'EDITED BY USER\n' > "$r2/note.txt"
git -C "$r2" add note.txt >/dev/null           # leaves ls-files --others
( cd "$r2" && bash "$GUARD" verify --restore >/dev/null 2>&1 ); rc=$?
check "staged file does not count as vanished" "$rc" "0"
check "staged file content NOT clobbered" "$(cat "$r2/note.txt")" "EDITED BY USER"

# --- 4. a new .gitignore rule must not look like deletion --------------------
r3=$(newrepo)
printf 'keep\n' > "$r3/build.log"
( cd "$r3" && bash "$GUARD" backup >/dev/null 2>&1 )
printf 'CHANGED\n' > "$r3/build.log"
echo "*.log" > "$r3/.gitignore"
( cd "$r3" && bash "$GUARD" verify --restore >/dev/null 2>&1 ); rc=$?
check "newly-ignored file does not count as vanished" "$rc" "0"
check "newly-ignored file NOT clobbered" "$(cat "$r3/build.log")" "CHANGED"

# --- 5. new artifacts are not findings ---------------------------------------
r4=$(newrepo); printf 'a\n' > "$r4/one.txt"
( cd "$r4" && bash "$GUARD" backup >/dev/null 2>&1 )
printf 'b\n' > "$r4/created-during-review.txt"
( cd "$r4" && bash "$GUARD" verify >/dev/null 2>&1 ); check "new artifact is not a finding" "$?" "0"

# --- 6. cross-invocation path stability, incl. from a subdirectory ------------
r5=$(newrepo); mkdir -p "$r5/sub"; printf 'a\n' > "$r5/sub/f.txt"
p1=$( cd "$r5" && bash "$GUARD" backup 2>/dev/null )
p2=$( cd "$r5/sub" && bash "$GUARD" backup 2>/dev/null )
check "same backup path from root and subdir" "$p1" "$p2"
( cd "$r5/sub" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify works from a subdir" "$?" "0"

# --- 7. worktree and canonical clone must not share a backup dir -------------
r6=$(newrepo)
git -C "$r6" worktree add -q "$r6/../wt-$$" -b wtbranch >/dev/null 2>&1
if [[ -d "$r6/../wt-$$" ]]; then
  printf 'a\n' > "$r6/only-in-clone.txt"; printf 'b\n' > "$r6/../wt-$$/only-in-wt.txt"
  a=$( cd "$r6" && bash "$GUARD" backup 2>/dev/null )
  b=$( cd "$r6/../wt-$$" && bash "$GUARD" backup 2>/dev/null )
  [[ "$a" != "$b" ]] && ok "worktree and clone keyed apart" || bad "worktree and clone keyed apart"
  ( cd "$r6" && bash "$GUARD" verify >/dev/null 2>&1 ); check "clone verify unaffected by worktree" "$?" "0"
else
  ok "worktree case skipped (could not create worktree)"
fi

# --- 8. rotation preserves the previous recovery copy ------------------------
r7=$(newrepo); printf 'a\n' > "$r7/keepme.txt"
( cd "$r7" && bash "$GUARD" backup >/dev/null 2>&1 )
( cd "$r7" && bash "$GUARD" backup >/dev/null 2>&1 )
base=$(dirname "$( cd "$r7" && bash "$GUARD" backup 2>/dev/null )")
[[ -n "$(find "$base" -maxdepth 1 -name 'prev-*' -print -quit)" ]] \
  && ok "previous backup rotated, not destroyed" || bad "previous backup rotated, not destroyed"

# --- 9. error contract --------------------------------------------------------
d=$(mktemp -d); ( cd "$d" && bash "$GUARD" backup >/dev/null 2>&1 ); check "non-git exits 2" "$?" "2"
r8=$(newrepo); ( cd "$r8" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify with no backup exits 2" "$?" "2"
( cd "$r8" && bash "$GUARD" bogus >/dev/null 2>&1 ); check "unknown subcommand exits 2" "$?" "2"

echo
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
