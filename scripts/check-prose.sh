#!/usr/bin/env bash
# check-prose.sh: enforce the repository's stated prose convention.
#
# WHY THIS EXISTS
# CLAUDE.md has said "Prose in this repository avoids em-dashes and emoji" for
# months. When it was finally measured there were 393 em-dashes across 26 files.
# A convention nothing checks is a preference, and this one had already decayed
# into one. The rule now fails `make validate` instead of being asserted.
#
# WHAT IS A VIOLATION
#   U+2014 EM DASH, anywhere in a scanned file.
#   ` -- ` used as sentence punctuation in markdown prose.
#
# WHAT IS NOT
# Hyphens inside identifiers, CLI flags, and compound modifiers are correct and
# common here: `us-east-2`, `--profile`, `ChatGPT-backed`. So is `--` as the
# POSIX end-of-options marker, which is what every current occurrence in this
# repo actually is (`git checkout HEAD -- path`, `dirname -- "$f"`, `cp -Pp --`).
# A check that flagged those would be turned off within a week, so the ` -- `
# rule applies to markdown only and skips fenced and inline code.
#
# KNOWN LIMIT
# A line carrying an ODD number of backticks leaves its unclosed span unstripped,
# so a ` -- ` inside it is reported. That line is malformed markdown already, and
# the repo has none, so this is left as a loud false positive rather than guessed
# at: the report names the exact line, which is enough to fix or exempt.
#
# USAGE
#   bash scripts/check-prose.sh            # report violations, exit 1 if any
#   bash scripts/check-prose.sh --list     # one `path:line: text` per violation
#
# EXIT: 0 clean, 1 violations found, 2 the check could not run.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$0")")" || exit 2

list=0
[[ "${1:-}" == "--list" ]] && list=1

# Files exempt from the em-dash rule, each with the reason it is exempt. This is
# an allowlist of two entries and it should stay small: every addition is a place
# the convention does not apply, and "it was easier" is not a reason.
#
# app-store-review-guidelines.md is a VERBATIM saved copy of Apple's published
# guidelines, shipped so the audit can cite exact rule text. Rewriting Apple's
# punctuation would corrupt the quotations the plugin's findings depend on.
# The two self-referential entries are not a loophole: a checker that cannot name
# the character it forbids cannot document itself, and a suite that cannot write a
# violating fixture cannot prove the checker fires. Both were found the honest way,
# by the check failing on them.
is_exempt() {
  case "$1" in
    plugins/apple-release/resources/app-store-review-guidelines.md) return 0 ;;
    scripts/check-prose.sh)      return 0 ;;  # names the characters it forbids
    scripts/check-prose.test.sh) return 0 ;;  # its fixtures must contain violations
    *) return 1 ;;
  esac
}

violations=0
report() { violations=$((violations+1)); [[ "$list" == 1 ]] && printf '%s\n' "$1"; }

# --- em dashes -------------------------------------------------------------
# Scanned across every tracked text file, not just markdown: the manifests carry
# user-facing description prose, and that is exactly where the convention is most
# visible. `git ls-files` rather than `find` so build output and untracked
# scratch files are never scanned.
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  is_exempt "$f" && continue
  case "$f" in *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip) continue ;; esac
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    report "$f:$hit"
  done < <(grep -nI '—' "$f" 2>/dev/null | cut -c1-160)
done < <(git ls-files 2>/dev/null)

# --- ` -- ` as sentence punctuation, markdown prose only -------------------
# awk tracks fenced-code state so a shell example inside ``` is skipped, and the
# inline-code strip removes `git checkout HEAD -- path` written mid-sentence.
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  is_exempt "$f" && continue
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    report "$f:$hit"
  done < <(awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }   # CommonMark allows either fence
    fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)          # drop inline code spans
      if (line ~ / -- /) printf "%d: %s\n", NR, substr($0, 1, 140)
    }' "$f" 2>/dev/null)
done < <(git ls-files '*.md' 2>/dev/null)

if [[ "$violations" -gt 0 ]]; then
  [[ "$list" == 0 ]] && printf '  %s prose violations (em-dash, or " -- " as punctuation)\n' "$violations"
  [[ "$list" == 0 ]] && printf '  run: bash scripts/check-prose.sh --list\n'
  exit 1
fi
exit 0
