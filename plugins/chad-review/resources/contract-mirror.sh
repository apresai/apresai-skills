#!/usr/bin/env bash
# contract-mirror.sh: reverse generated-contract reconciliation for the DRIFT
# pass (types/mirror).
#
# WHY THIS EXISTS
# The forward drift check regenerates a generated artifact and diffs the result,
# which catches a generated file that is stale against its spec. It is
# structurally blind to the reverse failure, because the reverse failure lives
# OUTSIDE every generated path: a handwritten mirror of the generated types that
# nothing regenerates and nothing diffs. That is the regist miss this script
# locks down. An openapi-typescript output file (api.generated.ts) gained
# SearchResult, SearchResults, Citation, CrossMeetingChatRequest, and
# CrossMeetingChatResponse schemas, while a handwritten api-client.ts kept
# mirror interfaces of the same names under a comment claiming the generated
# file "predates that addition and isn't regenerated". The comment was false by
# the time anyone read it: the schemas were in the generated file, the mirrors
# were redundant, and the two copies of the contract were free to drift apart
# with no check in either direction. Regenerate-and-diff can never see this,
# because the mirror is not generated and never will be.
#
# So this script walks the whole project, finds generated type artifacts, lists
# the names they define, then looks for HANDWRITTEN re-declarations of those
# same names, and for comments telling the mirror-instead-of-generated story.
# What stays with the skill is judgment: whether a re-declaration is a stale
# mirror or a deliberate twin, and whether a matched comment is truthful. There
# is deliberately NO stoplist of generic names: a generic name arrives with its
# declaration line as evidence, and the skill's confidence filter judges it.
# For the same reason test files are searched like any other file; the record
# carries the path, and the skill can see it is a test.
#
# USAGE
#   bash contract-mirror.sh        # scan the repo containing $PWD; no arguments
#
# The scan is whole-project BY DESIGN, never diff-scoped: the stale mirror is by
# definition outside the diff that touched the generated file, so a diff-scoped
# scan reproduces the exact blindness this script exists to remove. The skill
# decides when running it is worth the cost.
#
# OUTPUT
# One record per line, tab-separated. SUMMARY always prints, so "nothing found"
# arrives with counts behind it rather than as an unfalsifiable claim. A repo
# with no generated artifacts reports gen_files=0; that is the N/A shape, not
# an error.
#
#   GEN           <path>  <ts|go>  <glob|header|both>  names=N
#   MIRROR        <gen-path>  <name>  <handwritten-path>:<line>  <excerpt<=120>
#   STALECOMMENT  <path>:<line>  <nearest-mirror-name|->  <excerpt<=120>
#   OKGEN         <path>  names=N  mirrors=0
#   NOTE          <topic>  <detail>
#   SUMMARY       gen_files=N  names=M  mirrors=X  stale_comments=Y  skipped=S
#
# names=M counts every name extracted from generated files, summed per file.
# skipped=S counts names dropped at the global 400-name search cap, announced
# by a NOTE so the cap is never a silent claim of completeness. NO RECORD
# CARRIES AN EMPTY FIELD (freshness.sh documents why: consecutive tabs collapse
# under `IFS=$'\t' read` and silently shift every later field); `-` is the
# placeholder. Excerpts are squeezed to one line and at most 120 characters.
#
# BASH 3.2. macOS ships 3.2.57 and `#!/usr/bin/env bash` resolves to it, so no
# associative arrays and no `mapfile`. Set membership uses newline-delimited
# accumulators with `grep -qxF`, as freshness.sh does.
#
# EXIT: 0 whenever the scan ran. Findings are data, not failure. Non-zero means
# the script itself could not run.
set -uo pipefail

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 1

# Same prune list as freshness.sh, declared in both find and grep form side by
# side because freshness.sh learned that two separately maintained copies drift
# apart. `generated` directories are deliberately NOT pruned: a path containing
# /generated/ is one of the things being looked for.
PRUNE=( -name node_modules -o -name .git -o -name vendor -o -name target
        -o -name build -o -name dist -o -name .next -o -name cdk.out
        -o -name DerivedData -o -name Pods -o -name .build -o -name .dart_tool )
GREP_EXCLUDES=( --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor
                --exclude-dir=target --exclude-dir=build --exclude-dir=dist
                --exclude-dir=.next --exclude-dir=cdk.out --exclude-dir=DerivedData
                --exclude-dir=Pods --exclude-dir=.build --exclude-dir=.dart_tool )

NAME_CAP=400
CHUNK=50

# The header arm: what generators actually stamp into their first lines.
# Case-insensitive; covers Go's "Code generated ... DO NOT EDIT", the
# openapi-typescript banner ("This file was auto-generated ..." / "Do not make
# direct changes to the file."), and the named generators.
HEADER_PAT='code generated|auto-?generated|do not edit|do not make direct changes|generated by (openapi|oapi|protoc|swagger)'

# The stale-comment vocabulary, straight from the incident and its close
# variants: "predates that addition and isn't regenerated", "Hand-written here
# (rather than pulled from ...)", plus the usual out-of-sync and
# regenerate-later phrasings. BSD grep ERE: no \b, no -P; `is ?n.?t` absorbs
# the apostrophe in "isn't" without needing one in the pattern.
STALE_PAT='predates?|not regenerated|is ?n.?t regenerated|hand-?written here|rather than pulled from|out of (sync|date) with (the )?generated|regenerate (it )?(later|eventually)'

n_gen=0; n_names=0; n_search=0; n_skipped=0; n_mirror=0; n_stale=0
gen_set=""        # newline-delimited paths of generated files
gen_counts=""     # path \t extracted-name-count, one per line
search_names=""   # newline-delimited distinct names inside the cap
name_map=""       # name \t gen-path; the first declaring file wins
gen_mirrored=""   # gen paths that received at least one MIRROR
mirror_files=""   # handwritten files that received at least one MIRROR
mirror_locs=""    # file \t line \t name, one per MIRROR

# Membership over a newline-delimited accumulator (paths can contain spaces, so
# the space-delimited `case` trick is not safe). Same helper as freshness.sh.
in_set() { [[ -n "$2" ]] && printf '%s\n' "$2" | grep -qxF -- "$1"; }

# One record stays one line and no field is ever empty: tabs become spaces, the
# line is trimmed and clipped to 120 characters, and an empty result becomes `-`.
excerpt() {
  local e
  e=$(printf '%s' "$1" | tr '\t' ' ' | sed 's/^ *//;s/ *$//' | cut -c1-120)
  printf '%s' "${e:--}"
}

# Names a generated TS file defines. Two sources, because openapi-typescript
# exports NO per-schema symbols: every schema exists only as an object key under
# components.schemas, and the file's only exported symbol is the lowercase
# `components`. The export grep alone would report names=0 for exactly the file
# class the incident involved, so a second awk pass enters the schemas block,
# notes the indent of its first nested line, and prints the keys at that indent
# until the block closes back at the entry indent.
extract_names_ts() {
  local f="$1"
  grep -oE '^export (interface|type|enum|class) [A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null \
    | awk '{print $3}'
  awk '
    function ind(s,  i) {
      i = 0
      while (substr(s, i + 1, 1) == " " || substr(s, i + 1, 1) == "\t") i++
      return i
    }
    {
      t = $0; sub(/^[ \t]+/, "", t)
      if (inblk) {
        i = ind($0)
        if (t ~ /^\}/ && i <= entry) { inblk = 0; next }
        if (t != "" && keyind < 0) keyind = i
        if (i == keyind && match(t, /^"?[A-Za-z_][A-Za-z0-9_]*"?\??:/)) {
          k = substr(t, RSTART, RLENGTH); gsub(/["?:]/, "", k); print k
        }
        next
      }
      if (t ~ /^("?schemas"?\??:|components:)[ \t]*\{[ \t]*$/) {
        entry = ind($0); keyind = -1; inblk = 1
      }
    }' "$f" 2>/dev/null
  return 0
}

# Names a generated Go file defines: `type Name struct|interface` plus simple
# aliases (`type Name = Foo`, `type Name string`). One broad grep covers both,
# since the second field is the name either way. Declarations inside a
# `type (...)` block are indented and deliberately not chased; generated Go
# emits flat declarations.
extract_names_go() {
  grep -E '^type [A-Z][A-Za-z0-9_]* ' "$1" 2>/dev/null | awk '{print $2}'
  return 0
}

# Walk the tree once for .ts/.tsx/.go files and classify each against two arms:
# the glob arm (generator naming conventions and conventional paths) and the
# header arm (generator banners in the first 10 lines). Either is enough; GEN
# reports which fired so the evidence is on the record. Names are filtered to
# 3+ characters with an uppercase start, then capped globally at NAME_CAP for
# the mirror search; the cap announces what it dropped.
discover() {
  local f base glob header arm lang names cnt nm hdr
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    f=${f#./}
    base=${f##*/}
    glob=0; header=0
    case "$base" in *.generated.*|*.gen.go|*.gen.ts|*_gen.go|*_gen.*) glob=1 ;; esac
    case "/$f" in */generated/*) glob=1 ;; esac
    case "/$f" in */types/api.*) glob=1 ;; esac
    # Captured, then matched: `head | grep -q` under pipefail can report false
    # when grep exits before head finishes a very long minified header line.
    hdr=$(head -10 "$f" 2>/dev/null)
    if grep -qiE "$HEADER_PAT" <<<"$hdr"; then header=1; fi
    [[ "$glob" == 0 && "$header" == 0 ]] && continue
    if [[ "$glob" == 1 && "$header" == 1 ]]; then arm=both
    elif [[ "$glob" == 1 ]]; then arm=glob
    else arm=header
    fi
    case "$base" in *.go) lang=go ;; *) lang=ts ;; esac
    if [[ "$lang" == go ]]; then names=$(extract_names_go "$f")
    else names=$(extract_names_ts "$f")
    fi
    names=$(printf '%s\n' "$names" | grep -E '^[A-Z][A-Za-z0-9_]{2,}$' | sort -u)
    if [[ -n "$names" ]]; then cnt=$(printf '%s\n' "$names" | wc -l | tr -d ' '); else cnt=0; fi
    printf 'GEN\t%s\t%s\t%s\tnames=%s\n' "$f" "$lang" "$arm" "$cnt"
    n_gen=$((n_gen+1)); n_names=$((n_names+cnt))
    gen_set+="$f"$'\n'
    gen_counts+="$f	$cnt"$'\n'
    while IFS= read -r nm; do
      [[ -z "$nm" ]] && continue
      in_set "$nm" "$search_names" && continue
      if [[ "$n_search" -ge "$NAME_CAP" ]]; then n_skipped=$((n_skipped+1)); continue; fi
      search_names+="$nm"$'\n'
      name_map+="$nm	$f"$'\n'
      n_search=$((n_search+1))
    done <<< "$names"
  done < <(find . -maxdepth 8 \( "${PRUNE[@]}" \) -prune -o -type f \
             \( -name '*.ts' -o -name '*.tsx' -o -name '*.go' \) -print 2>/dev/null)
  # A cap that does not announce itself is a silent claim of completeness.
  if [[ "$n_skipped" -gt 0 ]]; then
    printf 'NOTE\tname-cap\tsearching %s of %s distinct names, %s dropped at the cap\n' \
      "$NAME_CAP" "$((n_search + n_skipped))" "$n_skipped"
  fi
  return 0
}

# One grep hit becomes a MIRROR record only if it clears three gates: the path
# is not itself a generated file (generated-vs-generated is regeneration, not a
# mirror), the declared name maps back to a searched name (the alternation can
# match inside a longer line whose declared identifier is something else), and
# the name resolves to the generated file that defined it.
process_hits() {
  local lang="$1" hits="$2" hit file rest lineno text name gp ex
  [[ -z "$hits" ]] && return 0
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file=${hit%%:*}; rest=${hit#*:}
    lineno=${rest%%:*}; text=${rest#*:}
    file=${file#./}
    in_set "$file" "$gen_set" && continue
    if [[ "$lang" == ts ]]; then
      name=$(printf '%s\n' "$text" \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?(declare[[:space:]]+)?(interface|type|enum|class)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\4/')
    else
      name=$(printf '%s\n' "$text" \
        | sed -E 's/^type[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/')
    fi
    in_set "$name" "$search_names" || continue
    gp=$(awk -F'\t' -v w="$name" '$1 == w { print $2; exit }' <<<"$name_map")
    [[ -z "$gp" ]] && continue
    ex=$(excerpt "$text")
    printf 'MIRROR\t%s\t%s\t%s:%s\t%s\n' "$gp" "$name" "$file" "$lineno" "$ex"
    n_mirror=$((n_mirror+1))
    in_set "$file" "$mirror_files" || mirror_files+="$file"$'\n'
    mirror_locs+="$file	$lineno	$name"$'\n'
    in_set "$gp" "$gen_mirrored" || gen_mirrored+="$gp"$'\n'
  done <<< "$hits"
  return 0
}

# The patterns demand a DECLARATION, anchored at line start: an import, a
# comment, or a string literal that mentions the name never matches, and the
# trailing boundary keeps SearchResult from matching inside SearchResults.
# BSD grep ERE has no \b, hence the explicit ([^A-Za-z0-9_]|$) class.
run_chunk() {
  local alts="$1" pat hits
  pat='^[[:space:]]*(export[[:space:]]+)?(declare[[:space:]]+)?(interface|type|enum|class)[[:space:]]+('"$alts"')([^A-Za-z0-9_]|$)'
  hits=$(grep -rnIE "$pat" . --include='*.ts' --include='*.tsx' "${GREP_EXCLUDES[@]}" 2>/dev/null)
  process_hits ts "$hits"
  pat='^type[[:space:]]+('"$alts"')[[:space:]]+(struct|interface)'
  hits=$(grep -rnIE "$pat" . --include='*.go' "${GREP_EXCLUDES[@]}" 2>/dev/null)
  process_hits go "$hits"
  return 0
}

# Batched, never per-name: names are joined 50 per ERE alternation, so 400
# names is 8 tree walks per language rather than 400. Both language patterns
# run for every chunk, which also catches a contract mirrored across languages.
find_mirrors() {
  local nm alts="" count=0
  [[ -z "$search_names" ]] && return 0
  while IFS= read -r nm; do
    [[ -z "$nm" ]] && continue
    if [[ -n "$alts" ]]; then alts+="|$nm"; else alts="$nm"; fi
    count=$((count+1))
    if [[ "$count" -ge "$CHUNK" ]]; then run_chunk "$alts"; alts=""; count=0; fi
  done <<< "$search_names"
  [[ -n "$alts" ]] && run_chunk "$alts"
  return 0
}

# Only files that already produced a MIRROR are scanned: the comment is
# evidence ABOUT a mirror, and scanning the whole tree for these phrases would
# bury the signal in ordinary prose. A hit must also look like a comment
# (line-start marker, or // or /* anywhere), so a string literal carrying the
# words does not fire. nearest-mirror-name ties the comment to a MIRROR in the
# same file within 10 lines either way; `-` when none is that close.
find_stale_comments() {
  local f hit lineno text near ex
  [[ -z "$mirror_files" ]] && return 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      lineno=${hit%%:*}; text=${hit#*:}
      printf '%s' "$text" | grep -qE '(^[[:space:]]*(#|\*))|//|/\*' || continue
      near=$(awk -F'\t' -v f="$f" -v l="$lineno" '
        $1 == f { d = $2 - l; if (d < 0) d = -d
                  if (d <= 10 && (bd == "" || d < bd)) { best = $3; bd = d } }
        END { if (best == "") print "-"; else print best }' <<<"$mirror_locs")
      ex=$(excerpt "$text")
      printf 'STALECOMMENT\t%s:%s\t%s\t%s\n' "$f" "$lineno" "$near" "$ex"
      n_stale=$((n_stale+1))
    done < <(grep -niE "$STALE_PAT" "$f" 2>/dev/null)
  done <<< "$mirror_files"
  return 0
}

# A generated file with no mirrors gets a positive record, so "no MIRROR rows"
# is distinguishable from "the file was never examined".
emit_okgen() {
  local f cnt
  [[ -z "$gen_set" ]] && return 0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    in_set "$f" "$gen_mirrored" && continue
    cnt=$(awk -F'\t' -v w="$f" '$1 == w { print $2; exit }' <<<"$gen_counts")
    printf 'OKGEN\t%s\tnames=%s\tmirrors=0\n' "$f" "${cnt:-0}"
  done <<< "$gen_set"
  return 0
}

discover
find_mirrors
find_stale_comments
emit_okgen
printf 'SUMMARY\tgen_files=%s\tnames=%s\tmirrors=%s\tstale_comments=%s\tskipped=%s\n' \
  "$n_gen" "$n_names" "$n_mirror" "$n_stale" "$n_skipped"
exit 0
