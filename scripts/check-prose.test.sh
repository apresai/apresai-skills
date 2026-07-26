#!/usr/bin/env bash
# check-prose.test.sh: suite for check-prose.sh.
#
# WHY THIS EXISTS
# The check gates `make validate`, so a false positive blocks every PR in the repo
# and a false negative makes the gate decorative. The interesting cases are all
# about NOT firing: ` -- ` is the POSIX end-of-options marker in every current
# occurrence here (`git checkout HEAD -- path`), and a check that flagged those
# would be switched off within a week.
#
# Every case builds a throwaway git repo under a temp dir, because the script
# scans `git ls-files` rather than walking the filesystem.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-prose.sh"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

newrepo(){
  d=$(mktemp -d)
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t )
  echo "$d"
}
# The script reads `git ls-files`, so content must be staged to be seen.
commit(){ ( cd "$1" && git add -A . >/dev/null 2>&1 ); }
run(){ ( cd "$1" && bash "$SCRIPT" >/dev/null 2>&1; echo $? ); }
listing(){ ( cd "$1" && bash "$SCRIPT" --list 2>/dev/null ); }

clean(){ # clean <desc> <repo>   -> expects exit 0
  if [[ "$(run "$2")" == 0 ]]; then ok "$1"; else
    bad "$1"; printf '       flagged:\n%s\n' "$(listing "$2" | sed 's/^/         /')"; fi
}
dirty(){ # dirty <desc> <repo>   -> expects exit 1
  if [[ "$(run "$2")" == 1 ]]; then ok "$1"; else bad "$1 (expected a violation, got none)"; fi
}

echo "check-prose.sh suite"

# --- an em-dash in prose is a violation -----------------------------------
r=$(newrepo); printf 'Some prose — with a dash.\n' > "$r/a.md"; commit "$r"
dirty "em-dash in markdown is caught" "$r"
# Capture first rather than piping: this file runs under `set -o pipefail`, and
# check-prose.sh exits 1 by design when it finds something, so `listing | grep -q`
# reports the pipeline as failed even when grep matched.
out=$(listing "$r")
if grep -q '^a\.md:1:' <<<"$out"; then ok "--list gives path:line"; else
  bad "--list gives path:line"; printf '       got: %s\n' "$out"; fi
rm -rf "$r"

# --- em-dashes are caught outside markdown too ----------------------------
# The manifests carry user-facing description prose and that is where the
# convention is most visible, so the scan is not markdown-only.
r=$(newrepo); printf '{"description":"one — two"}\n' > "$r/x.json"; commit "$r"
dirty "em-dash in a JSON description is caught" "$r"
rm -rf "$r"

# --- clean prose passes ---------------------------------------------------
r=$(newrepo); printf 'Some prose, with a comma. And a colon: like this.\n' > "$r/a.md"; commit "$r"
clean "clean prose passes" "$r"
rm -rf "$r"

# --- THE FALSE POSITIVES THAT WOULD GET THIS TURNED OFF -------------------
# Every ` -- ` in this repo today is an end-of-options marker, not punctuation.
r=$(newrepo)
cat > "$r/a.md" <<'DOC'
Restore it with `git checkout HEAD -- .claude-plugin/marketplace.json`; the bare
form does nothing.

```bash
cp -Pp -- "$src" "$dst"
mkdir -p "$(dirname -- "$f")"
git checkout HEAD -- path/to/file
```

Pass `--profile` and `--dry-run`, and note that `us-east-2` and `ChatGPT-backed`
are ordinary hyphens.
DOC
commit "$r"
clean "end-of-options -- in inline code is not punctuation" "$r"
rm -rf "$r"

r=$(newrepo)
printf 'Text before.\n\n```\nsome -- thing in a fence\n```\n\nText after.\n' > "$r/a.md"; commit "$r"
clean "fenced code is skipped entirely" "$r"
rm -rf "$r"

r=$(newrepo); printf 'Run it with --dry-run and --force flags.\n' > "$r/a.md"; commit "$r"
clean "CLI flags are never flagged" "$r"
rm -rf "$r"

r=$(newrepo); printf 'Deploy to us-east-2 using a ChatGPT-backed model.\n' > "$r/a.md"; commit "$r"
clean "hyphens in identifiers are never flagged" "$r"
rm -rf "$r"

# --- but real ` -- ` punctuation in prose IS caught ------------------------
r=$(newrepo); printf 'This is the point -- it reads as a tell.\n' > "$r/a.md"; commit "$r"
dirty "spaced -- as sentence punctuation is caught" "$r"
rm -rf "$r"

# --- the exemption, and its limits ----------------------------------------
# Apple's saved guidelines are quoted verbatim by the audit plugin; rewriting
# their punctuation would corrupt the rule text the findings cite.
r=$(newrepo)
mkdir -p "$r/plugins/apple-release/resources"
printf 'Apple text — quoted verbatim.\n' > "$r/plugins/apple-release/resources/app-store-review-guidelines.md"
commit "$r"
clean "the verbatim Apple document is exempt" "$r"
# The exemption is one exact path, not a directory and not a glob.
printf 'Our own prose — not exempt.\n' > "$r/plugins/apple-release/resources/other.md"; commit "$r"
dirty "a sibling file in the same dir is NOT exempt" "$r"
rm -rf "$r"

# --- the self-referential exemptions ---------------------------------------
# This suite writes violating fixtures on purpose and the checker names the
# characters it forbids, so both are exempt. If that exemption is ever dropped,
# `make validate` fails on the very files that prove it works, which looks like a
# real violation and invites someone to "fix" the fixtures instead.
r=$(newrepo)
mkdir -p "$r/scripts"
printf 'fixture with an em-dash \xe2\x80\x94 on purpose\n' > "$r/scripts/check-prose.test.sh"
printf 'checker naming \xe2\x80\x94 the character\n' > "$r/scripts/check-prose.sh"
commit "$r"
clean "the checker and its own suite are exempt" "$r"
rm -rf "$r"

# --- untracked files are out of scope -------------------------------------
# The scan is `git ls-files`, so scratch files and build output never gate a PR.
r=$(newrepo); printf 'clean\n' > "$r/a.md"; commit "$r"
printf 'untracked — dash\n' > "$r/scratch.md"
clean "untracked files are not scanned" "$r"
rm -rf "$r"

# --- binaries must not be scanned or crash the run ------------------------
r=$(newrepo); printf 'clean\n' > "$r/a.md"; printf '\x00\x01\x02binary\xff' > "$r/logo.png"; commit "$r"
clean "binary files are skipped" "$r"
rm -rf "$r"

# --- exit codes are the contract ------------------------------------------
r=$(newrepo); printf 'x — y\n' > "$r/a.md"; commit "$r"
[[ "$(run "$r")" == 1 ]] && ok "exit 1 when violations exist" || bad "exit 1 when violations exist"
rm -rf "$r"

echo
echo "check-prose.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
