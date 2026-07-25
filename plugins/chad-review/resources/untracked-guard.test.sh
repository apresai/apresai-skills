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

# Isolate from the invoking user's git config. A global `core.excludesFile` that
# ignores a fixture file makes `git commit` fail, and an unredirected failure
# message would otherwise become the fixture PATH (see newrepo). Everything below
# also runs under a scratch HOME so nothing reads or writes the real one.
WORKDIR=$(mktemp -d) || { echo "cannot create scratch dir" >&2; exit 99; }
[[ -d "$WORKDIR" ]] || { echo "scratch dir is not a directory" >&2; exit 99; }
trap 'rm -rf "$WORKDIR"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# GIT_CONFIG_GLOBAL does not cover the XDG ignore file, and HOME is read for
# other paths, so point both at the scratch dir. Without this a personal
# ~/.config/git/ignore entry could make a fixture file invisible and fail the run.
export HOME="$WORKDIR" XDG_CONFIG_HOME="$WORKDIR/xdg"
mkdir -p "$XDG_CONFIG_HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

# Returns ONLY the fixture path on stdout. Every git call is fully redirected:
# a stray line from a failing command would become part of the path the caller
# then runs `mkdir -p` and `git clean` against, i.e. inside the caller's repo.
newrepo() {
  local d
  d=$(mktemp -d "$WORKDIR/repo.XXXXXX") || return 1
  {
    git -C "$d" init -q . &&
    echo tracked > "$d/tracked.txt" &&
    git -C "$d" add -A &&
    git -C "$d" commit -qm init
  } >/dev/null 2>&1 || { echo "FIXTURE SETUP FAILED" >&2; return 1; }
  printf '%s' "$d"
}

# Guard every fixture: if newrepo ever returns something that is not a directory
# inside WORKDIR, stop immediately rather than operating on the caller's tree.
usable() {
  case "$1" in "$WORKDIR"/*) [[ -d "$1" ]] && return 0 ;; esac
  echo "  FATAL: fixture path is not inside the scratch dir: [$1]" >&2
  exit 99
}

echo "untracked-guard.sh test suite"

# --- 1. round trip across separate invocations, hostile filenames -------------
r=$(newrepo) || exit 99; usable "$r"; mkdir -p "$r/a/b/c"
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
r2=$(newrepo) || exit 99; usable "$r2"
printf 'original\n' > "$r2/note.txt"
bk2=$( cd "$r2" && bash "$GUARD" backup 2>/dev/null )
[[ -f "$bk2/note.txt" ]] && ok "blocker fixture: file really was backed up" || bad "blocker fixture: file really was backed up"
printf 'EDITED BY USER\n' > "$r2/note.txt"
git -C "$r2" add note.txt >/dev/null           # leaves ls-files --others
( cd "$r2" && bash "$GUARD" verify --restore >/dev/null 2>&1 ); rc=$?
check "staged file does not count as vanished" "$rc" "0"
check "staged file content NOT clobbered" "$(cat "$r2/note.txt")" "EDITED BY USER"

# --- 4. a new .gitignore rule must not look like deletion --------------------
r3=$(newrepo) || exit 99; usable "$r3"
printf 'keep\n' > "$r3/build.log"
bk3=$( cd "$r3" && bash "$GUARD" backup 2>/dev/null )
[[ -f "$bk3/build.log" ]] && ok "ignore fixture: file really was backed up" || bad "ignore fixture: file really was backed up"
printf 'CHANGED\n' > "$r3/build.log"
echo "*.log" > "$r3/.gitignore"
( cd "$r3" && bash "$GUARD" verify --restore >/dev/null 2>&1 ); rc=$?
check "newly-ignored file does not count as vanished" "$rc" "0"
check "newly-ignored file NOT clobbered" "$(cat "$r3/build.log")" "CHANGED"

# --- 5. new artifacts are not findings ---------------------------------------
r4=$(newrepo) || exit 99; usable "$r4"; printf 'a\n' > "$r4/one.txt"
( cd "$r4" && bash "$GUARD" backup >/dev/null 2>&1 )
printf 'b\n' > "$r4/created-during-review.txt"
( cd "$r4" && bash "$GUARD" verify >/dev/null 2>&1 ); check "new artifact is not a finding" "$?" "0"

# --- 6. cross-invocation path stability, incl. from a subdirectory ------------
r5=$(newrepo) || exit 99; usable "$r5"; mkdir -p "$r5/sub"; printf 'a\n' > "$r5/sub/f.txt"
p1=$( cd "$r5" && bash "$GUARD" backup 2>/dev/null )
p2=$( cd "$r5/sub" && bash "$GUARD" backup 2>/dev/null )
check "same backup path from root and subdir" "$p1" "$p2"
( cd "$r5/sub" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify works from a subdir" "$?" "0"

# --- 7. worktree and canonical clone must not share a backup dir -------------
r6=$(newrepo) || exit 99; usable "$r6"
git -C "$r6" worktree add -q "$WORKDIR/wt-$$" -b wtbranch >/dev/null 2>&1
if [[ -d "$WORKDIR/wt-$$" ]]; then
  printf 'a\n' > "$r6/only-in-clone.txt"; printf 'b\n' > "$WORKDIR/wt-$$/only-in-wt.txt"
  a=$( cd "$r6" && bash "$GUARD" backup 2>/dev/null )
  b=$( cd "$WORKDIR/wt-$$" && bash "$GUARD" backup 2>/dev/null )
  [[ "$a" != "$b" ]] && ok "worktree and clone keyed apart" || bad "worktree and clone keyed apart"
  ( cd "$r6" && bash "$GUARD" verify >/dev/null 2>&1 ); check "clone verify unaffected by worktree" "$?" "0"
else
  printf "  skip %s\n" "worktree case (could not create worktree)"
fi

# --- 8. rotation preserves the previous recovery copy ------------------------
r7=$(newrepo) || exit 99; usable "$r7"; printf 'a\n' > "$r7/keepme.txt"
( cd "$r7" && bash "$GUARD" backup >/dev/null 2>&1 )
( cd "$r7" && bash "$GUARD" backup >/dev/null 2>&1 )
base=$(dirname "$( cd "$r7" && bash "$GUARD" backup 2>/dev/null )")
[[ -n "$(find "$base" -maxdepth 1 -name 'prev-*' -print -quit)" ]] \
  && ok "previous backup rotated, not destroyed" || bad "previous backup rotated, not destroyed"

# --- 9. error contract --------------------------------------------------------
d=$(mktemp -d "$WORKDIR/nogit.XXXXXX"); ( cd "$d" && bash "$GUARD" backup >/dev/null 2>&1 ); check "non-git exits 2" "$?" "2"
r8=$(newrepo) || exit 99; usable "$r8"; ( cd "$r8" && bash "$GUARD" verify >/dev/null 2>&1 ); check "verify with no backup exits 2" "$?" "2"
( cd "$r8" && bash "$GUARD" bogus >/dev/null 2>&1 ); check "unknown subcommand exits 2" "$?" "2"

# --- 10. behaviours added after the suite was written ------------------------
r9=$(newrepo) || exit 99; usable "$r9"
( cd "$r9" && bash "$GUARD" backup --restore >/dev/null 2>&1 ); check "backup --restore is a usage error" "$?" "2"

r10=$(newrepo) || exit 99; usable "$r10"; printf 'x\n' > "$r10/clean.txt"
( cd "$r10" && bash "$GUARD" backup >/dev/null 2>&1 )
noise=$( cd "$r10" && bash "$GUARD" verify 2>&1 1>/dev/null )
check "verify is silent on stderr for a clean tree" "$noise" ""

r11=$(newrepo) || exit 99; usable "$r11"
printf 'x\n' > "$r11/$(printf 'bad\nname.txt')" 2>/dev/null
( cd "$r11" && bash "$GUARD" backup >/dev/null 2>&1 )
if ( cd "$r11" && bash "$GUARD" verify 2>&1 1>/dev/null ) | grep -q newline; then
  ok "newline-in-path warning fires"
else
  bad "newline-in-path warning fires"
fi

r12=$(newrepo) || exit 99; usable "$r12"; printf 'x\n' > "$r12/f.txt"
for _ in 1 2 3 4 5 6 7 8; do ( cd "$r12" && bash "$GUARD" backup >/dev/null 2>&1 ); done
b12=$(dirname "$( cd "$r12" && bash "$GUARD" backup 2>/dev/null )")
check "rotations pruned to newest 5" "$(find "$b12" -maxdepth 1 -name 'prev-*' | wc -l | tr -d ' ')" "5"

echo
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
