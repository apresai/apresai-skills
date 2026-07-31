#!/usr/bin/env bash
# docs-drift.sh: everything chad-review's DRIFT pass [docs/status] and
# [docs/live-value] can determine without judgment.
#
# WHY THIS EXISTS
# Three documentation-drift shapes shipped on a real repo and survived review,
# because catching them takes a cross-file comparison nobody was mechanically
# running:
#   1. A master-plan doc gained a top banner reading "EXECUTION COMPLETE (...).
#      This is the historical execution record." while line 5 still said
#      "**Status:** Active plan", line 12 still called the file "the working
#      master plan", and a live "How to Use This Plan" section still gave
#      imperative steps. Both claims were quotable, so a reader landing on
#      either one got a coin flip about whether the plan was live.
#   2. A device checklist said "target build 117/118 or later" while the
#      tracked BUILD_NUMBER file read 152. The floor was correct when written;
#      nothing ever compared it against the authority again.
#   3. An index doc classified a doc as superseded while the doc itself still
#      called itself active, so the catalog and the doc disagreed about which
#      one to trust.
# All three are deterministic string comparisons against files already in the
# tree. The judgment (is a stale floor worth a finding, which side of a
# contradiction is right) stays in the skill; the comparison lives here, where
# it cannot be skipped. The test suite replays all three shapes with synthetic
# fixtures.
#
# USAGE
#   bash docs-drift.sh                    # changed docs: diff HEAD + staged + untracked
#   bash docs-drift.sh --last-commit      # docs named by HEAD's own commit
#   bash docs-drift.sh [--last-commit] -- <file>...
#                                         # explicit scope, overrides discovery
# Explicit paths are taken relative to the repo root (the script cds there).
# Outside a git repo discovery finds nothing, explicit paths still work, and
# the run still exits 0 with a SUMMARY.
#
# OUTPUT
# One record per line on stdout, tab-separated, `-` for an absent field.
#
#   AUTHORITY <source-path> <build|version> <value>
#   DOC       <path> <status-bearing|prose> lines=<changed> markers=<hist=N,active=N,checkbox=N|none>
#   MARKER    <path>:<line> <hist|active|imperative|checkbox|canonical> <excerpt>
#   STALE     <path>:<line> <found-floor> <authority-value> <authority-source> <section:<heading>|top> <excerpt>
#   INDEXED   <classifier>:<line> <doc-path> <historical|live> <excerpt>
#   CONTRA    <path> status-conflict <hist-line>:<active-line> <hist-excerpt> => <active-excerpt>
#   CONTRA    <doc-path> index-conflict <classifier>:<line> <self>-vs-<index> <excerpt>
#   OKDOC     <path> markers=<N> stale=0 contra=0
#   SKIP      <path> <binary|too-large|missing|not-markdown>
#   NOTE      <topic> <detail>
#   SUMMARY   docs=N status_bearing=M authorities=A stale=X contra=Y indexed=Z skipped=S
#
# NO RECORD CARRIES AN EMPTY FIELD. Tab is an IFS whitespace character, so one
# empty cell silently shifts every field after it when read back (see
# freshness.sh for the verified failure). Excerpts are squeezed to <=120 chars
# with tabs converted to spaces.
#
# BASH 3.2. macOS ships 3.2.57 and `#!/usr/bin/env bash` can resolve to it, so
# no associative arrays, no mapfile, no ${var,,}. Set membership uses
# newline-delimited accumulators with `grep -qxF`. BSD grep: no -P, no \b; BSD
# sed: -E only. The per-line classification runs in one awk pass per doc, not
# a bash loop, because a 5000-line doc through per-line shell forks takes
# minutes and one awk pass takes milliseconds.
#
# EXIT: 0 whenever the scan ran. Findings are data, not failure. 2 for a
# usage error, 1 only when the script itself cannot run.
set -uo pipefail

LINE_CAP=5000       # lines classified per doc; past this a NOTE announces the cut
BYTE_CAP=5000000    # docs above this are SKIP too-large rather than half-read
MARKER_CAP=3        # MARKER records emitted per class per file
NEIGHBOR_CAP=20     # classifier docs scanned per doc

# Class regexes, matched against the LOWERCASED line (headings for the section
# and imperative classes). Kept in variables here so the vocabulary is one
# block to read and extend, and exported because the classifier awk reads them
# through ENVIRON: `awk -v` reprocesses backslash escapes, which silently
# mangles \[ and \*, while ENVIRON passes the string through untouched.
DD_HIST_RE='execution complete|historical (execution )?record|this is the historical|superseded by|archived|no longer (current|maintained|the plan)'
DD_ACTIVE_RE='status:? *(\*\*)? *(active|current|in progress)|working master plan|single live (backlog|plan|doc)|this document is the (working|live|current)'
DD_IMPERATIVE_RE='how to use this (plan|document)|next steps|execution order'
DD_CHECKBOX_RE='^[[:space:]]*- \[[ x]\]'
DD_HIST_SECTION_RE='histor|archive|snapshot|superseded|execution record|changelog|post-?mortem'
# Written without {n} intervals: the one-true-awk on stock macOS predates
# reliable ERE interval support.
DD_DATED_RE='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]|session of'
DD_FLOOR_IDIOM_RE='or (later|newer|higher)|at least|minimum|target|[0-9][+]'
export DD_HIST_RE DD_ACTIVE_RE DD_IMPERATIVE_RE DD_CHECKBOX_RE \
       DD_HIST_SECTION_RE DD_DATED_RE DD_FLOOR_IDIOM_RE

# Classification vocabulary for how OTHER docs classify this one.
IDX_HIST_RE='superseded( by)?|historical|archived|no longer'
IDX_LIVE_RE='single live|the live (backlog|plan)|current (plan|master)|working master'

PRUNE=( -name node_modules -o -name .git -o -name vendor -o -name target
        -o -name build -o -name dist -o -name .next -o -name cdk.out
        -o -name DerivedData -o -name Pods -o -name .build )

usage() { echo "usage: docs-drift.sh [--last-commit] [-- <file>...]" >&2; exit 2; }

mode=worktree
explicit_files=""
seen_dd=0
for a in "$@"; do
  if [[ "$seen_dd" -eq 1 ]]; then explicit_files+="$a"$'\n'; continue; fi
  case "$a" in
    --last-commit) mode=last-commit ;;
    --)            seen_dd=1 ;;
    *)             usage ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 1

n_authority=0; n_docs=0; n_statusb=0; n_stale=0; n_contra=0; n_indexed=0; n_skipped=0
best_build=""; best_build_src="-"; best_version=""; best_version_src="-"
build_vals=""
authority_basenames=""
noted_noauth_build=0; noted_noauth_version=0
docs=""; nonmd=""
# Per-doc results handed from classify_doc to the main loop.
file_skipped=0; file_stale=0; file_contra=0; file_markers=0; self_class=none

# Membership over a newline-delimited accumulator (paths can contain spaces,
# so the space-delimited `case` trick is not safe).
in_set() { [[ -n "$2" ]] && printf '%s\n' "$2" | grep -qxF -- "$1"; }

# One record stays one line: tabs to spaces, trimmed, capped at 120 chars,
# and never empty (the `-` placeholder keeps the field count stable).
excerpt() {
  local e
  e=$(printf '%s' "$1" | tr '\t' ' ' | sed -E 's/^ +//; s/ +$//' | cut -c1-120)
  printf '%s' "${e:--}"
}

# Dotted-numeric compare, the same shape freshness.sh uses for FIX grouping.
# Prints 1, 0, or -1 as $1 is greater, equal, or less than $2.
cmpv() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, ".")
    m = (na > nb) ? na : nb
    for (i = 1; i <= m; i++)
      if ((x[i] + 0) != (y[i] + 0)) { print ((x[i] + 0) > (y[i] + 0)) ? 1 : -1; exit }
    print 0
  }'
}

# --- scope -----------------------------------------------------------------

changed_docs() {
  if [[ "$mode" == "last-commit" ]]; then
    git show --name-only --pretty=format: HEAD 2>/dev/null
  else
    # Union of unstaged, staged, and untracked. Deleted docs surface here too
    # and land as SKIP missing rather than being silently dropped.
    git diff HEAD --name-only 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  fi | grep -E '\.(md|mdx)$' | LC_ALL=C sort -u
  return 0
}

changed_line_count() {
  local f="$1" a b
  if [[ "$mode" == "last-commit" ]]; then
    git show --numstat --pretty=format: HEAD -- "$f" 2>/dev/null \
      | awk -F'\t' '{ if ($1 != "-") s += $1; if ($2 != "-") s += $2 } END { print s + 0 }'
    return 0
  fi
  if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    # `git diff HEAD` already folds staged content in, so ADDING the cached
    # numbers would double-count every staged hunk. Take the larger of the two
    # sums instead: that is the dedupe, and it also covers the file whose only
    # changes are staged.
    a=$(git diff HEAD --numstat -- "$f" 2>/dev/null \
        | awk -F'\t' '{ if ($1 != "-") s += $1; if ($2 != "-") s += $2 } END { print s + 0 }')
    b=$(git diff --cached --numstat -- "$f" 2>/dev/null \
        | awk -F'\t' '{ if ($1 != "-") s += $1; if ($2 != "-") s += $2 } END { print s + 0 }')
    if [[ "${b:-0}" -gt "${a:-0}" ]]; then printf '%s' "${b:-0}"; else printf '%s' "${a:-0}"; fi
  else
    # Untracked (or outside a git repo entirely): the whole file is the change.
    a=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    printf '%s' "${a:-0}"
  fi
}

# --- authorities -----------------------------------------------------------

add_build() {
  local src="$1" v="$2" b
  printf 'AUTHORITY\t%s\tbuild\t%s\n' "$src" "$v"
  n_authority=$((n_authority+1))
  build_vals+="$v"$'\n'
  if [[ -z "$best_build" || "$v" -gt "$best_build" ]]; then
    best_build="$v"; best_build_src="$src"
  fi
  b=${src##*/}
  in_set "$b" "$authority_basenames" || authority_basenames+="$b"$'\n'
}

add_version() {
  local src="$1" v="$2" b
  printf 'AUTHORITY\t%s\tversion\t%s\n' "$src" "$v"
  n_authority=$((n_authority+1))
  if [[ -z "$best_version" || "$(cmpv "$v" "$best_version")" == "1" ]]; then
    best_version="$v"; best_version_src="$src"
  fi
  b=${src##*/}
  in_set "$b" "$authority_basenames" || authority_basenames+="$b"$'\n'
}

# .version out of a JSON manifest. jq when it works, sed when it does not:
# falling back on OUTPUT rather than on `command -v` means a broken or stub jq
# degrades to the sed path instead of silently dropping the authority.
json_version() {
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v=$(jq -r '.version // empty' "$1" 2>/dev/null)
  fi
  if ! printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
    v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$1" 2>/dev/null | head -1)
  fi
  printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)+$' && printf '%s' "$v"
  return 0
}

find_authorities() {
  local dirs="." d sf name v line rhs fname pb pj ndistinct vals
  dirs="."$'\n'
  # The three scalar names are checked at the repo root and next to each doc
  # in scope: a plugin or an ios/ subtree keeps its own BUILD_NUMBER.
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    d=$(dirname "$d")
    in_set "$d" "$dirs" || dirs+="$d"$'\n'
  done <<< "$docs"

  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    for name in BUILD_NUMBER VERSION SHIPPED_VERSION; do
      if [[ "$d" == "." ]]; then sf="$name"; else sf="$d/$name"; fi
      [[ -f "$sf" ]] || continue
      v=$(head -1 "$sf" 2>/dev/null | tr -d '[:space:]')
      # Plain digits are a build number; a dotted numeric is a version. A
      # template value like `1.1.{build}` is neither and is skipped: resolving
      # it would mean guessing, and a wrong authority is worse than none.
      if printf '%s' "$v" | grep -qE '^[0-9]+$'; then
        add_build "$sf" "$v"
      elif printf '%s' "$v" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
        add_version "$sf" "$v"
      fi
    done
  done <<< "$dirs"

  for pj in package.json .claude-plugin/plugin.json plugins/*/.claude-plugin/plugin.json; do
    [[ -f "$pj" ]] || continue
    v=$(json_version "$pj")
    [[ -n "$v" ]] && add_version "$pj" "$v"
  done

  if [[ -f Makefile ]]; then
    line=$(grep -E '^BUILD_NUM(BER)? *:?=' Makefile 2>/dev/null | head -1)
    if [[ -n "$line" ]]; then
      rhs=$(printf '%s' "${line#*=}" | sed -E 's/^ +//; s/ +$//')
      # A `$(shell cat FILE)` right-hand side is resolved through the named
      # file, so the Makefile authority agrees with the scalar it reads.
      fname=$(printf '%s' "$rhs" | sed -nE 's/.*\$\(shell +cat +([^)]+)\).*/\1/p' | sed -E 's/^ +//; s/ +$//')
      v=""
      if [[ -n "$fname" ]]; then
        [[ -f "$fname" ]] && v=$(head -1 "$fname" 2>/dev/null | tr -d '[:space:]')
      else
        v="$rhs"
      fi
      printf '%s' "$v" | grep -qE '^[0-9]+$' && add_build Makefile "$v"
    fi
  fi

  # Bounded on purpose: an unpruned find in a big worktree walks node_modules
  # and DerivedData for minutes. One AUTHORITY per pbxproj, carrying the max
  # CURRENT_PROJECT_VERSION in that file (multi-target projects repeat it).
  while IFS= read -r pb; do
    [[ -z "$pb" ]] && continue
    pb=${pb#./}
    v=$(grep -oE 'CURRENT_PROJECT_VERSION = [0-9]+' "$pb" 2>/dev/null \
        | grep -oE '[0-9]+' | sort -n | tail -1)
    [[ -n "$v" ]] && add_build "$pb" "$v"
  done < <(find . -maxdepth 6 \( "${PRUNE[@]}" \) -prune -o -type f -name project.pbxproj -print 2>/dev/null)

  # Disagreeing build authorities all get their AUTHORITY row; floors compare
  # against the max, and the disagreement itself is a named fact.
  ndistinct=$(printf '%s' "$build_vals" | LC_ALL=C sort -u | grep -c .)
  if [[ "$ndistinct" -gt 1 ]]; then
    vals=$(printf '%s' "$build_vals" | grep . | sort -un | tr '\n' ',' | sed 's/,$//')
    printf 'NOTE\tauthority-disagree\tbuild authorities disagree (%s); comparing floors against the max %s from %s\n' \
      "$vals" "$best_build" "$best_build_src"
  fi
  return 0
}

# --- per-doc classification ------------------------------------------------

# One awk pass per doc. Emits intermediate records for bash to post-process:
#   MK <line> <class> <text>                          markers
#   FL <line> <build|version> <found> <flag> <section> <text>   floor candidates
# flag is ok, dated, or hist; a canonical reference is diverted to an MK
# canonical record INSTEAD of a floor, which is suppression rule 1.
classify_awk() {
  awk '
    function trimsq(s) { gsub(/\t/, " ", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # A whole-token match of any discovered authority basename, dots escaped.
    # This also covers the $(cat BUILD_NUMBER) spelling: the parens around the
    # basename are non-token characters, so the token match fires there too.
    function names_authority(line,   i, re) {
      for (i = 1; i <= nb; i++) {
        if (bn[i] == "") continue
        re = bn[i]; gsub(/\./, "\\.", re)
        re = "(^|[^A-Za-z0-9_.])" re "([^A-Za-z0-9_.]|$)"
        if (line ~ re) return 1
      }
      return 0
    }
    # Max integer on the line in the `build 117/118` and `131+` shapes.
    function build_floor(lc,   s, seg, max, n, parts, i, v) {
      max = -1
      s = lc
      while (match(s, /build[ :]*[0-9]+(\/[0-9]+)?/)) {
        seg = substr(s, RSTART, RLENGTH)
        n = split(seg, parts, /[^0-9]+/)
        for (i = 1; i <= n; i++)
          if (parts[i] != "") { v = parts[i] + 0; if (v > max) max = v }
        s = substr(s, RSTART + RLENGTH)
      }
      s = lc
      while (match(s, /[0-9]+\+/)) {
        v = substr(s, RSTART, RLENGTH - 1) + 0
        if (v > max) max = v
        s = substr(s, RSTART + RLENGTH)
      }
      return max
    }
    BEGIN {
      hist_re    = ENVIRON["DD_HIST_RE"];         active_re = ENVIRON["DD_ACTIVE_RE"]
      imper_re   = ENVIRON["DD_IMPERATIVE_RE"];   checkbox_re = ENVIRON["DD_CHECKBOX_RE"]
      histsec_re = ENVIRON["DD_HIST_SECTION_RE"]; dated_re = ENVIRON["DD_DATED_RE"]
      idiom_re   = ENVIRON["DD_FLOOR_IDIOM_RE"]
      nb = split(ENVIRON["DD_AUTH_BASENAMES"], bn, "\n")
      heading = ""; in_hist = 0
    }
    {
      line = $0
      lc = tolower(line)
      if (line ~ /^#/) {
        match(line, /^#+/)
        if (RLENGTH <= 6 && substr(line, RLENGTH + 1, 1) == " ") {
          heading = trimsq(substr(line, RLENGTH + 2))
          in_hist = (tolower(heading) ~ histsec_re) ? 1 : 0
          # The imperative class is heading-only by design: "next steps" in
          # running prose is conversation, as a heading it is live structure.
          if (lc ~ imper_re) printf "MK\t%d\timperative\t%s\n", NR, trimsq(line)
        }
      }
      if (line ~ checkbox_re) printf "MK\t%d\tcheckbox\t%s\n", NR, trimsq(line)
      if (lc ~ hist_re)       printf "MK\t%d\thist\t%s\n", NR, trimsq(line)
      if (lc ~ active_re)     printf "MK\t%d\tactive\t%s\n", NR, trimsq(line)
      if (lc ~ /build|version/) {
        if (names_authority(line)) {
          # Suppression rule 1, first match wins: a line that names the
          # authority file is pointing AT the source of truth, not asserting
          # a value that can go stale.
          printf "MK\t%d\tcanonical\t%s\n", NR, trimsq(line)
          next
        }
        # A floor needs a floor idiom; a bare number is never a candidate.
        if (lc ~ idiom_re) {
          flag = "ok"
          if (lc ~ dated_re) flag = "dated"
          else if (in_hist)  flag = "hist"
          sec = (heading == "") ? "top" : "section:" substr(heading, 1, 120)
          if (lc ~ /build[ :]*[0-9]/) {
            bf = build_floor(lc)
            if (bf >= 0) printf "FL\t%d\tbuild\t%d\t%s\t%s\t%s\n", NR, bf, flag, sec, trimsq(line)
          }
          if (match(lc, /version[ :]*[0-9]+(\.[0-9]+)+/)) {
            vf = substr(lc, RSTART, RLENGTH)
            sub(/^version[ :]*/, "", vf)
            printf "FL\t%d\tversion\t%s\t%s\t%s\t%s\n", NR, vf, flag, sec, trimsq(line)
          }
        }
      }
    }
  '
}

count_class() { cut -f1,3 "$parsed" | grep -cxF "$(printf 'MK\t%s' "$1")"; }

classify_doc() {
  local f="$1"
  local parsed total changed bytes cls mk auth asrc rec pair
  local hist_n active_n checkbox_n imper_n canon_n floor_n
  local ch ca ck ci cc n tag f2 f3 f4 f5 f6 f7
  local fh_line fh_text fa_line fa_text stale_buf wholly

  file_skipped=0; file_stale=0; file_contra=0; file_markers=0; self_class=none

  if [[ ! -f "$f" ]]; then
    printf 'SKIP\t%s\tmissing\n' "$f"; n_skipped=$((n_skipped+1)); file_skipped=1; return 0
  fi
  bytes=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  if [[ "${bytes:-0}" -gt "$BYTE_CAP" ]]; then
    printf 'SKIP\t%s\ttoo-large\n' "$f"; n_skipped=$((n_skipped+1)); file_skipped=1; return 0
  fi
  # grep -I is the same binary detector freshness.sh leans on. A non-empty
  # file where no line matches `.` is binary; the -s guard keeps a genuinely
  # empty doc out of that bucket.
  if [[ -s "$f" ]] && ! grep -Iq . "$f" 2>/dev/null; then
    printf 'SKIP\t%s\tbinary\n' "$f"; n_skipped=$((n_skipped+1)); file_skipped=1; return 0
  fi

  total=$(wc -l < "$f" 2>/dev/null | tr -d ' '); total=${total:-0}
  changed=$(changed_line_count "$f"); changed=${changed:-0}

  parsed=$(mktemp)
  if [[ "$total" -gt "$LINE_CAP" ]]; then
    # A cap that does not announce itself is a silent claim of completeness.
    printf 'NOTE\tline-cap\t%s has %s lines; classified the first %s only\n' "$f" "$total" "$LINE_CAP"
    head -"$LINE_CAP" "$f" | classify_awk > "$parsed"
  else
    classify_awk < "$f" > "$parsed"
  fi

  hist_n=$(count_class hist);         active_n=$(count_class active)
  checkbox_n=$(count_class checkbox); imper_n=$(count_class imperative)
  canon_n=$(count_class canonical)
  floor_n=$(cut -f1 "$parsed" | grep -cxF FL)
  file_markers=$((hist_n + active_n + checkbox_n + imper_n + canon_n))

  # Status-bearing means the doc makes claims this scanner can check, or the
  # change is big enough (>= 25 lines) that the skill should read it anyway.
  if [[ $((file_markers + floor_n)) -gt 0 || "$changed" -ge 25 ]]; then
    cls=status-bearing
  else
    cls=prose
  fi
  if [[ $((hist_n + active_n + checkbox_n)) -eq 0 ]]; then
    mk=none
  else
    mk="hist=$hist_n,active=$active_n,checkbox=$checkbox_n"
  fi
  printf 'DOC\t%s\t%s\tlines=%s\tmarkers=%s\n' "$f" "$cls" "$changed" "$mk"
  n_docs=$((n_docs+1))
  [[ "$cls" == status-bearing ]] && n_statusb=$((n_statusb+1))

  ch=0; ca=0; ck=0; ci=0; cc=0
  while IFS=$'\t' read -r tag f2 f3 f4 f5 f6 f7; do
    [[ "$tag" == MK ]] || continue
    case "$f3" in
      hist)       ch=$((ch+1)); n=$ch ;;
      active)     ca=$((ca+1)); n=$ca ;;
      checkbox)   ck=$((ck+1)); n=$ck ;;
      imperative) ci=$((ci+1)); n=$ci ;;
      canonical)  cc=$((cc+1)); n=$cc ;;
      *) continue ;;
    esac
    [[ "$n" -le "$MARKER_CAP" ]] || continue
    printf 'MARKER\t%s:%s\t%s\t%s\n' "$f" "$f2" "$f3" "$(excerpt "$f4")"
  done < "$parsed"
  for pair in "hist:$hist_n" "active:$active_n" "checkbox:$checkbox_n" \
              "imperative:$imper_n" "canonical:$canon_n"; do
    n=${pair##*:}
    if [[ "$n" -gt "$MARKER_CAP" ]]; then
      printf 'NOTE\tmarker-cap\t%s: %s markers shown %s of %s\n' "$f" "${pair%%:*}" "$MARKER_CAP" "$n"
    fi
  done

  fh_line=$(awk -F'\t' '$1 == "MK" && $3 == "hist"   { print $2; exit }' "$parsed")
  fh_text=$(awk -F'\t' '$1 == "MK" && $3 == "hist"   { print $4; exit }' "$parsed")
  fa_line=$(awk -F'\t' '$1 == "MK" && $3 == "active" { print $2; exit }' "$parsed")
  fa_text=$(awk -F'\t' '$1 == "MK" && $3 == "active" { print $4; exit }' "$parsed")

  # STALE candidates are BUFFERED, not printed, because whole-file historical
  # status (suppression rule 4) is only known once the whole pass is done: the
  # banner that makes a report historical can sit above OR below the floor.
  stale_buf=""
  while IFS=$'\t' read -r tag f2 f3 f4 f5 f6 f7; do
    [[ "$tag" == FL ]] || continue
    case "$f5" in dated|hist) continue ;; esac
    if [[ "$f3" == build ]]; then
      if [[ -z "$best_build" ]]; then
        if [[ "$noted_noauth_build" -eq 0 ]]; then
          printf 'NOTE\tno-authority\tbuild floors found but no build authority discovered; staleness not evaluated\n'
          noted_noauth_build=1
        fi
        continue
      fi
      [[ "$f4" -lt "$best_build" ]] || continue
      auth=$best_build; asrc=$best_build_src
    else
      if [[ -z "$best_version" ]]; then
        if [[ "$noted_noauth_version" -eq 0 ]]; then
          printf 'NOTE\tno-authority\tversion floors found but no version authority discovered; staleness not evaluated\n'
          noted_noauth_version=1
        fi
        continue
      fi
      [[ "$(cmpv "$f4" "$best_version")" == "-1" ]] || continue
      auth=$best_version; asrc=$best_version_src
    fi
    printf -v rec 'STALE\t%s:%s\t%s\t%s\t%s\t%s\t%s' \
      "$f" "$f2" "$f4" "$auth" "$asrc" "$f6" "$(excerpt "$f7")"
    stale_buf+="$rec"$'\n'
  done < "$parsed"

  wholly=0
  [[ "$hist_n" -ge 1 && "$active_n" -eq 0 ]] && wholly=1
  if [[ -n "$stale_buf" && "$wholly" -eq 0 ]]; then
    printf '%s' "$stale_buf"
    file_stale=$(printf '%s' "$stale_buf" | grep -c .)
    n_stale=$((n_stale + file_stale))
  fi

  if [[ "$hist_n" -ge 1 && "$active_n" -ge 1 ]]; then
    printf 'CONTRA\t%s\tstatus-conflict\t%s:%s\t%s => %s\n' \
      "$f" "$fh_line" "$fa_line" "$(excerpt "$fh_text")" "$(excerpt "$fa_text")"
    file_contra=$((file_contra+1)); n_contra=$((n_contra+1))
    self_class=conflict
  elif [[ "$hist_n" -ge 1 ]]; then
    self_class=historical
  elif [[ "$active_n" -ge 1 ]]; then
    self_class=live
  fi

  rm -f "$parsed"
  return 0
}

# --- how other docs classify this one --------------------------------------

scan_neighbors() {
  local f="$1" base dir tmpc total c hit lineno text lc iclass g
  base=${f##*/}
  dir=$(dirname "$f")
  tmpc=$(mktemp)
  # Candidates: siblings, root-level docs, and anything that names this doc.
  {
    for g in "$dir"/*.md; do [[ -f "$g" ]] && printf '%s\n' "${g#./}"; done
    for g in *.md; do [[ -f "$g" ]] && printf '%s\n' "$g"; done
    grep -rlF --include='*.md' \
      --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
      --exclude-dir=target --exclude-dir=build --exclude-dir=dist \
      --exclude-dir=.next --exclude-dir=cdk.out --exclude-dir=DerivedData \
      --exclude-dir=Pods --exclude-dir=.build \
      -- "$base" . 2>/dev/null | sed 's|^\./||'
  } | grep -vxF -- "$f" | LC_ALL=C sort -u > "$tmpc"

  total=$(wc -l < "$tmpc" | tr -d ' ')
  if [[ "${total:-0}" -gt "$NEIGHBOR_CAP" ]]; then
    printf 'NOTE\tneighbor-cap\t%s: scanning %s of %s neighbor docs\n' "$f" "$NEIGHBOR_CAP" "$total"
  fi

  while IFS= read -r c; do
    [[ -z "$c" || ! -f "$c" ]] && continue
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      lineno=${hit%%:*}; text=${hit#*:}
      lc=$(printf '%s' "$text" | tr 'A-Z' 'a-z')
      if printf '%s\n' "$lc" | grep -qE "$IDX_HIST_RE"; then iclass=historical
      elif printf '%s\n' "$lc" | grep -qE "$IDX_LIVE_RE"; then iclass=live
      else continue; fi
      printf 'INDEXED\t%s:%s\t%s\t%s\t%s\n' "$c" "$lineno" "$f" "$iclass" "$(excerpt "$text")"
      n_indexed=$((n_indexed+1))
      # A doc that already contradicts ITSELF is a status-conflict, not an
      # index-conflict; with no self-classification there is nothing for the
      # index to disagree with.
      if [[ "$self_class" == live && "$iclass" == historical ]] \
         || [[ "$self_class" == historical && "$iclass" == live ]]; then
        printf 'CONTRA\t%s\tindex-conflict\t%s:%s\t%s-vs-%s\t%s\n' \
          "$f" "$c" "$lineno" "$self_class" "$iclass" "$(excerpt "$text")"
        file_contra=$((file_contra+1)); n_contra=$((n_contra+1))
      fi
    done < <(grep -nF -- "$base" "$c" 2>/dev/null)
  done < <(head -"$NEIGHBOR_CAP" "$tmpc")
  rm -f "$tmpc"
  return 0
}

# --- main ------------------------------------------------------------------

if [[ -n "$explicit_files" ]]; then
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    case "$e" in
      *.md|*.mdx) docs+="$e"$'\n' ;;
      *)          nonmd+="$e"$'\n' ;;
    esac
  done <<< "$explicit_files"
else
  docs=$(changed_docs)
fi

find_authorities
# The classifier awk reads the basename list through ENVIRON, same reason as
# the class regexes above.
export DD_AUTH_BASENAMES="$authority_basenames"

while IFS= read -r e; do
  [[ -z "$e" ]] && continue
  printf 'SKIP\t%s\tnot-markdown\n' "$e"
  n_skipped=$((n_skipped+1))
done <<< "$nonmd"

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  classify_doc "$f"
  [[ "$file_skipped" -eq 1 ]] && continue
  scan_neighbors "$f"
  if [[ "$file_stale" -eq 0 && "$file_contra" -eq 0 ]]; then
    printf 'OKDOC\t%s\tmarkers=%s\tstale=0\tcontra=0\n' "$f" "$file_markers"
  fi
done <<< "$docs"

printf 'SUMMARY\tdocs=%s\tstatus_bearing=%s\tauthorities=%s\tstale=%s\tcontra=%s\tindexed=%s\tskipped=%s\n' \
  "$n_docs" "$n_statusb" "$n_authority" "$n_stale" "$n_contra" "$n_indexed" "$n_skipped"
exit 0
