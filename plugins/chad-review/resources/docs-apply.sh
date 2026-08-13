#!/usr/bin/env bash
# docs-apply.sh: apply STALE live-value records from docs-drift.sh.
#
# Only STALE. CONTRA is judgment and is printed, not rewritten.
# Historical snapshots are already suppressed by docs-drift.sh.
#
# USAGE
#   bash docs-apply.sh [--last-commit]
#
# EXIT 0 if the scan ran. 2 for usage. 1 if a rewrite was attempted and failed.
set -euo pipefail

mode_args=()
for arg in "$@"; do
  case "$arg" in
    --last-commit) mode_args+=(--last-commit) ;;
    *) echo "usage: docs-apply.sh [--last-commit]" >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 1

drift=$(bash "$here/docs-drift.sh" "${mode_args[@]+"${mode_args[@]}"}" 2>/dev/null || true)

applied=0
skipped=0

exec_path() {
  case "$1" in
    CLAUDE.md|*/CLAUDE.md|Claude.md|*/Claude.md|AGENTS.md|*/AGENTS.md|SKILL.md|*/SKILL.md) return 0 ;;
    .claude/*|*/.claude/*|prompts/*|*/prompts/*) return 0 ;;
    */commands/*|commands/*|*/agents/*|agents/*|*/skills/*|skills/*) return 0 ;;
  esac
  return 1
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  kind=${line%%$'\t'*}
  case "$kind" in
    CONTRA)
      printf 'REPORT\t%s\n' "$line"
      continue
      ;;
    STALE) ;;
    *) continue ;;
  esac
  rest=${line#*$'\t'}
  loc=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  found=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  authority=${rest%%$'\t'*}
  path=${loc%%:*}
  lineno=${loc##*:}
  if exec_path "$path"; then
    printf 'SKIP\texec-md\t%s\n' "$loc"
    skipped=$((skipped+1))
    continue
  fi
  if [[ ! -f "$path" ]]; then
    printf 'SKIP\tmissing\t%s\n' "$path"
    skipped=$((skipped+1))
    continue
  fi
  if [[ ! "$lineno" =~ ^[0-9]+$ ]]; then
    printf 'SKIP\tbad-line\t%s\n' "$loc"
    skipped=$((skipped+1))
    continue
  fi
  src_line=$(sed -n "${lineno}p" "$path" 2>/dev/null || true)
  if [[ -z "$src_line" ]]; then
    printf 'SKIP\tempty-line\t%s\n' "$loc"
    skipped=$((skipped+1))
    continue
  fi
  occ=$(printf '%s' "$src_line" | grep -oF "$found" | grep -c . || true)
  if [[ "${occ:-0}" -ne 1 ]]; then
    printf 'SKIP\tnot-unique\t%s\tfound=%s\tocc=%s\n' "$loc" "$found" "${occ:-0}"
    skipped=$((skipped+1))
    continue
  fi
  new_line=${src_line/"$found"/"$authority"}
  tmp=$(mktemp)
  awk -v n="$lineno" -v repl="$new_line" 'NR==n {print repl; next} {print}' "$path" > "$tmp"
  mv "$tmp" "$path"
  printf 'APPLIED\t%s\t%s -> %s\n' "$loc" "$found" "$authority"
  applied=$((applied+1))
done <<< "$drift"

printf 'SUMMARY\tapplied=%s\tskipped=%s\n' "$applied" "$skipped"
