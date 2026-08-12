#!/usr/bin/env bash
# Tests for check-mirrors.sh: identical mirror passes; drifted, missing-mirror,
# and missing-original all fail with distinct messages.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
sut="$here/check-mirrors.sh"
fails=0

run_case() {
  local name="$1" want_exit="$2" want_prefix="$3"
  local d out got
  d=$(mktemp -d)
  case "$name" in
    identical)        printf 'same\n' > "$d/CLAUDE.md"; cp "$d/CLAUDE.md" "$d/AGENTS.md" ;;
    drifted)          printf 'same\n' > "$d/CLAUDE.md"; printf 'other\n' > "$d/AGENTS.md" ;;
    missing-mirror)   printf 'same\n' > "$d/CLAUDE.md" ;;
    missing-original) printf 'same\n' > "$d/AGENTS.md" ;;
  esac
  out=$(bash "$sut" "$d" 2>&1)
  got=$?
  if [ "$got" -ne "$want_exit" ]; then
    echo "FAIL: $name expected exit $want_exit, got $got"
    fails=1
  elif ! printf '%s' "$out" | grep -q "^$want_prefix"; then
    echo "FAIL: $name expected message starting with '$want_prefix', got: $out"
    fails=1
  else
    echo "ok: $name"
  fi
  rm -rf "$d"
}

run_case identical 0 "OK:"
run_case drifted 1 "DRIFT:"
run_case missing-mirror 1 "MISSING: AGENTS.md"
run_case missing-original 1 "MISSING: CLAUDE.md"

exit $fails
