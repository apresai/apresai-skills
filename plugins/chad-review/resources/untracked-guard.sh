#!/usr/bin/env bash
# untracked-guard.sh backup|verify [--restore]
#
# WHY THIS IS A SCRIPT AND NOT A SNIPPET IN THE SKILL
# chad-review's read-only guarantee is prompt wording, not tool restriction: the
# reviewer agents hold Bash, Edit, and Write, and the review runs the project's
# own test and codegen commands. Any of those can take untracked files with them
# (`git stash -u`, `git clean`, `git checkout`). On 2026-06-14 exactly that
# happened: an untracked test file under review was gone from disk afterwards
# while the review reported success.
#
# This started life as two bash snippets pasted into the skill. Three review
# rounds found three defects in them, all the same shape: a model runs `backup`
# and `verify` in two SEPARATE Bash calls, which are two separate shells, so
# anything held in a variable (`$$`, `$BK`) is gone by the second call. Snippets
# also duplicated the -z/quoting handling, and got it right in one place and
# wrong in the other, which made a non-ASCII filename look deleted and triggered
# a restore that WROTE to the tree.
#
# A script fixes the class: the backup path is derived the same way in both
# subcommands because it is the same code, quoting is handled once, and the whole
# thing can be tested. Read-only except for `verify --restore`, which only ever
# puts back a file that was already there.
#
# USAGE
#   untracked-guard.sh backup           # before the fan-out. Prints the backup path.
#   untracked-guard.sh verify           # after. Lists files that vanished. Exit 1 if any.
#   untracked-guard.sh verify --restore # same, and puts them back.
set -euo pipefail

usage() { echo "usage: untracked-guard.sh backup|verify [--restore]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
cmd="$1"; shift
restore=0
for a in "$@"; do case "$a" in --restore) restore=1 ;; *) usage ;; esac; done
[[ "$cmd" == "backup" && $restore -eq 1 ]] && usage

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository" >&2; exit 2; }
root=$(git rev-parse --show-toplevel)

# Deterministic per WORKING TREE, computed identically by both subcommands.
# Keyed on the toplevel, NOT `--git-common-dir`: that returns the same path for a
# worktree and its canonical clone, which share a .git but have completely
# different untracked files. Sharing a backup dir between them would let a
# backup in one rotate away the other's recovery copy, and would make `verify`
# compare one tree's live files against the other's saved list, reporting every
# file as vanished and restoring them into the wrong tree.
key="$root"
if command -v shasum >/dev/null 2>&1; then
  hash=$(printf '%s' "$key" | shasum | cut -c1-16)
elif command -v sha1sum >/dev/null 2>&1; then
  hash=$(printf '%s' "$key" | sha1sum | cut -c1-16)
else
  # No hasher: slug the WHOLE path. A suffix would collide for two repos sharing
  # a tail (…/a/app and …/b/app), and a collision here means one repo's backup
  # rotates away another's and restore writes across trees.
  hash=$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')
fi
base="${TMPDIR:-/tmp}/chad-review-untracked/$hash"
BK="$base/current"

# List untracked files NUL-separated, from the repo root, with quoting disabled
# so a non-ASCII path arrives literally instead of C-quoted. Both subcommands
# call this, so they cannot disagree about what "untracked" means.
list_untracked() {
  git -C "$root" -c core.quotepath=false ls-files --others --exclude-standard -z
}

case "$cmd" in
  backup)
    # Never destroy the previous backup: it may be the only surviving copy of a
    # file the last review lost. Rotate it aside instead.
    if [[ -d "$BK" ]]; then
      # Name is `prev-<ts>-<NNN>`: `date` alone is not unique for two backups in
      # the same second, and a failed `mv` would leave the previous run's entries
      # in place, where they would then look like files that vanished.
      #
      # The counter starts ABOVE every counter already present for this second,
      # not at the first free slot. Pruning frees the low numbers, so a
      # first-free-slot search would hand the NEWEST rotation the LOWEST name,
      # and the prune below (which orders by name) would then delete it first,
      # keeping the five oldest instead of the five newest.
      ts=$(date +%Y%m%d-%H%M%S)
      last=$({ find "$base" -maxdepth 1 -name "prev-$ts-*" -print 2>/dev/null || true; } \
             | sed "s|.*/prev-$ts-||" | LC_ALL=C sort -n | tail -1)
      # 10# so a zero-padded counter is read as decimal, not octal (008 is not
      # a valid octal literal and would abort the script under `set -e`).
      if [[ -n "$last" ]]; then i=$((10#$last + 1)); else i=0; fi
      dest=$(printf '%s/prev-%s-%03d' "$base" "$ts" "$i")
      while [[ -e "$dest" ]]; do i=$((i+1)); dest=$(printf '%s/prev-%s-%03d' "$base" "$ts" "$i"); done
      mv "$BK" "$dest" || { echo "could not rotate previous backup aside" >&2; exit 1; }
    fi
    # Capture the listing ONCE, up front: running it twice raced the check
    # against the data it was meant to validate.
    listing=$(mktemp); trap 'rm -f "$listing"' EXIT
    list_untracked > "$listing" 2>/dev/null || { echo "could not list untracked files; refusing to claim a backup" >&2; exit 1; }
    mkdir -p "$BK"; chmod 700 "$base" "$BK"
    # Keep the newest 5 rotations; unbounded copies of a large tree add up.
    # Ordering is by NAME, so no `stat`, whose flags differ between BSD and GNU
    # (`-f` means --file-system on GNU and would emit filesystem info straight
    # into a list feeding `rm -rf`). Sort the basenames, not the full paths, so
    # dashes in $TMPDIR cannot shift the field positions: date and time reverse
    # lexically, the counter reverse NUMERICALLY so a 4-digit counter still
    # sorts above 999. `|| true` because an empty match is normal and would
    # otherwise abort under `pipefail`.
    { find "$base" -maxdepth 1 -name 'prev-*' -exec basename {} \; 2>/dev/null || true; } \
      | LC_ALL=C sort -t- -k2,2r -k3,3r -k4,4nr | tail -n +6 \
      | while IFS= read -r old; do [[ -n "$old" ]] && rm -rf "${base:?}/$old"; done || true
    n=0; failed=0
    while IFS= read -r -d '' f; do
      mkdir -p "$BK/$(dirname -- "$f")"
      # -P keeps a symlink a symlink instead of copying through it (and works on
      # a dangling one); `--` and the ./ prefix survive a leading-dash filename.
      if cp -Pp -- "$root/./$f" "$BK/$f" 2>/dev/null; then
        n=$((n+1))
      else
        echo "BACKUP FAILED: $f" >&2; failed=$((failed+1))
      fi
    done < "$listing"
    echo "$BK"
    echo "backed up $n untracked file(s)" >&2
    [[ $failed -eq 0 ]] || { echo "$failed file(s) could not be backed up; do not review an unprotected tree" >&2; exit 1; }
    ;;

  verify)
    [[ -d "$BK" ]] || { echo "no backup found at $BK; run 'untracked-guard.sh backup' first" >&2; exit 2; }
    # The comparison below is line-based (comm has no NUL mode), so a filename
    # containing a literal newline cannot be compared safely. Name them and skip
    # rather than silently mis-pairing them with another file.
    # Capture the listing ONCE, as backup does: three separate calls raced the
    # same data the checks are meant to agree about.
    live="$(mktemp)"; saved="$(mktemp)"; raw="$(mktemp)"
    trap 'rm -f "$live" "$saved" "$raw"' EXIT
    list_untracked > "$raw" 2>/dev/null || { echo "could not list untracked files; cannot verify" >&2; exit 2; }

    # Count PATHS (NUL-separated records) that contain a newline, using the same
    # `read -r -d ''` idiom `backup` uses. Two shorter spellings were tried and
    # both were silently wrong: `grep -c '\n'` never matches under BSD grep, and
    # `awk 'BEGIN{RS="\0"}'` sets RS to the EMPTY string under BWK awk (the only
    # awk on stock macOS), which is paragraph mode, so it examined just the first
    # path. Verified: `awk 'BEGIN{RS="\0"; print length(RS)}'` prints 0 there.
    nl_count=0
    while IFS= read -r -d '' p; do
      case $p in *$'\n'*) nl_count=$((nl_count+1)) ;; esac
    done < "$raw"
    if [[ "$nl_count" -gt 0 ]]; then
      echo "warning: $nl_count untracked path(s) contain a newline; not covered by this check" >&2
    fi
    tr '\0' '\n' < "$raw" | LC_ALL=C sort > "$live"
    ( cd "$BK" && find . \( -type f -o -type l \) -print | sed 's|^\./||' ) | LC_ALL=C sort > "$saved"
    candidates=$(LC_ALL=C comm -13 "$live" "$saved" || true)

    # A file leaves `ls-files --others` for several reasons, and only one of them
    # is "deleted": `git add` stages it, a new .gitignore rule hides it, or it
    # gets committed. Treating those as vanished and "restoring" would overwrite
    # the user's live edits with the pre-review copy, which is a destructive
    # write, not a recovery. Only a file that is genuinely absent FROM DISK
    # counts, so re-check each candidate.
    missing=""
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if [[ ! -e "$root/$f" && ! -L "$root/$f" ]]; then
        missing+="$f"$'\n'
      fi
    done <<< "$candidates"
    missing=${missing%$'\n'}

    if [[ -z "$missing" ]]; then
      echo "all untracked files survived the review"
      exit 0
    fi
    echo "UNTRACKED FILES VANISHED DURING THIS REVIEW:" >&2
    printf '%s\n' "$missing" >&2
    if [[ $restore -eq 1 ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Belt and braces: the disk check above already proved it absent, but a
        # restore must never overwrite something that exists.
        if [[ -e "$root/$f" || -L "$root/$f" ]]; then
          echo "skipped (path now exists): $f" >&2; continue
        fi
        if ! mkdir -p "$root/$(dirname -- "$f")" 2>/dev/null; then
          echo "RESTORE FAILED (cannot create parent): $f" >&2; continue
        fi
        if cp -Pp -- "$BK/$f" "$root/./$f" 2>/dev/null; then
          echo "restored: $f" >&2
        else
          echo "RESTORE FAILED: $f (copy is at $BK/$f)" >&2
        fi
      done <<< "$missing"
    fi
    exit 1
    ;;

  *) usage ;;
esac
