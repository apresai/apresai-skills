#!/usr/bin/env bash
# AGENTS.md must be a byte-identical mirror of CLAUDE.md. The mirror exists for
# tools that read AGENTS.md (Codex); CLAUDE.md is the editable original. A
# reworded mirror is how ".claude-plugin/" once became ".Codex-plugin/", so the
# only acceptable difference is none.
# Usage: check-mirrors.sh [dir]   (defaults to the current directory)
set -u
dir="${1:-.}"
orig="$dir/CLAUDE.md"
mirror="$dir/AGENTS.md"

if [ ! -f "$orig" ]; then
  echo "MISSING: CLAUDE.md (the editable original must exist)"
  exit 1
fi
if [ ! -f "$mirror" ]; then
  echo "MISSING: AGENTS.md (create it: cp CLAUDE.md AGENTS.md)"
  exit 1
fi
if cmp -s "$orig" "$mirror"; then
  echo "OK: AGENTS.md is a byte-identical mirror of CLAUDE.md"
  exit 0
fi
echo "DRIFT: AGENTS.md differs from CLAUDE.md. If the change belongs in the guidance, make it in CLAUDE.md, then refresh: cp CLAUDE.md AGENTS.md"
exit 1
