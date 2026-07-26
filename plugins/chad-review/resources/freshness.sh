#!/usr/bin/env bash
# freshness.sh: everything pass 5 can determine without judgment.
#
# WHY THIS IS A SCRIPT
# Finding manifests, reading pinned versions, spotting version-bearing strings in
# files that are not manifests, and running a vulnerability scanner are all
# deterministic. They were 80 lines of English asking a model to run greps. What a
# model still has to decide is whether a gap is worth taking now and whether a
# version string in prose is a prescription or a warning. That judgment stays in
# the skill; everything mechanical is here.
#
# The same reasoning that made chad-review-route.sh a script rather than a
# paragraph. A script's conditions cannot silently disagree with the prose around
# them, because there is no prose around them.
#
# THE COVERAGE INVARIANT
# No output shape may say or imply "scanned" for an ecosystem nothing scanned.
# This is the same rule as "never report clean because no scanner was installed",
# one level up, and it exists because the weaker version shipped and failed. On a
# real repo (regist, 2026-07-26) osv-scanner covered Go and npm but never walked
# `ios/ReGist.xcodeproj/.../swiftpm/Package.resolved`, because `.gitignore` has
# `ios/*.xcodeproj` and osv-scanner respects .gitignore. Three swift-nio
# advisories were invisible, one at CVSS 8.7, higher than anything in the npm set
# that WAS reported. Nothing in the output hinted the Swift graph was unexamined.
#
# So discovery and scanning are now cross-checked against each other, and every
# discovered ecosystem gets a COVERAGE record saying whether anything looked at it.
#
# TWO SCANNER INVOCATIONS, AND WHY IT CANNOT BE ONE
# Pass 1 is `osv-scanner -r .`: fast, and it recognizes far more formats than the
# allowlist below. It respects .gitignore, which is the hole.
# Pass 2 is `osv-scanner -L <path> ...` for exactly the lockfiles this script found
# that pass 1 did not report scanning. It ignores .gitignore.
# They cannot be merged. Verified on osv-scanner 2.4.0:
#   -r . -L <path>          aborts the whole run, no results at all
#   -L <good> -L <bad>      aborts on the first name with no extractor, exit 127
#   --no-ignore -r .        91s instead of 0.8s and 843 findings, because it walks
#                           node_modules, Pods, and DerivedData
# The abort behavior is why `lscan_ok` is a verified allowlist rather than a guess:
# one wrong name costs the entire scan, so an unknown name is discovery-only.
#
# USAGE
#   bash freshness.sh              # audit the repo containing $PWD
#   bash freshness.sh --scan-only  # skip discovery, just run the vuln scanner
#
# OUTPUT
# Labeled blocks on stdout, one record per line, tab-separated. Empty blocks are
# omitted. SUMMARY always prints, so "nothing found" arrives with counts behind it
# rather than as an unfalsifiable claim.
#
#   MANIFEST  <path>  <ecosystem>  <manifest|lock>  <scannable|discovery-only>  <tracked|gitignored>
#   DEP       <manifest>  <name>  <pinned>
#   RUNTIME   <manifest>  <name>  <constraint>
#   REF       <file>:<line>  <identifier>  <surrounding line>
#   PREREQ    <binary>  <where it is required>
#   SCANNED   <path>  <tool>
#   SCAN      <tool>  <result>
#   FIX       <source>  <package>  <current>  <target>  <advisories>  <max CVSS>
#   COVERAGE  <ecosystem>  <covered|GAP>  <detail>
#   NOTE      <topic>  <detail>
#   SUMMARY   files=N ecosystems=M scanned_ecosystems=S coverage_gaps=G manifests=X
#             deps=Y refs=Z prereqs=P
#
# REF records carry their surrounding line ON PURPOSE. `NODEJS_20_X reached EOL`
# is a correct warning, not a finding, and only the context distinguishes it from
# a prescription. Stripping it here would force the judgment step to guess.
#
# FIX records are the remediation view of SCAN. 21 advisories on regist collapse to
# 10 upgrades, and one of them (next 16.2.10 -> 16.2.11) closes nine. The grouping
# key is (package, source, installed version) with the highest fixed version, NOT
# package alone: brace-expansion appears at three installed versions across two
# lockfiles with two different fixed versions, so a package-only key would print
# one row with a wrong target.
#
# BASH 3.2. macOS ships 3.2.57 and `#!/usr/bin/env bash` resolves to it, so there
# are no associative arrays and no `mapfile`. Set membership uses newline-delimited
# accumulators with `grep -qxF` (newline, not space, because paths contain spaces).
#
# EXIT: 0 whenever the audit ran. Findings are data, not failure. Non-zero means
# the script itself broke, which is the only thing a caller should treat as an
# error. Note osv-scanner exits 1 when it FINDS something and 127 on an
# unextractable -L path, so neither of those is a scanner failure either.
set -uo pipefail

scan_only=0
[[ "${1:-}" == "--scan-only" ]] && scan_only=1

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 1
# osv-scanner prints absolute paths derived from its own cwd, while
# `git rev-parse --show-toplevel` returns the RESOLVED path and `pwd` the logical
# one. On macOS those differ (/var vs /private/var), so both sides of the coverage
# comparison go through realpath rather than a string prefix strip.
root_phys=$(pwd -P)

PRUNE=( -name node_modules -o -name .git -o -name vendor -o -name target
        -o -name build -o -name dist -o -name .next -o -name cdk.out
        -o -name DerivedData -o -name Pods -o -name .build -o -name .dart_tool )

REF_CAP=200

n_manifest=0; n_dep=0; n_ref=0; n_prereq=0; n_gap=0
ecosystems=""; scanned_ecos=""
discovered=""     # path \t ecosystem \t role, one per line
ignored=""        # newline-delimited paths git ignores
lock_targets=""   # newline-delimited paths that are safe to hand to -L
scanned=""        # newline-delimited paths some scanner actually read

note_eco()  { case " $ecosystems "   in *" $1 "*) ;; *) ecosystems+="$1 " ;;   esac; }
note_seco() { case " $scanned_ecos " in *" $1 "*) ;; *) scanned_ecos+="$1 " ;; esac; }

# Membership over a newline-delimited accumulator. Paths can contain spaces, so
# the space-delimited `case` trick used for ecosystem names is not safe here.
in_set() { [[ -n "$2" ]] && printf '%s\n' "$2" | grep -qxF -- "$1"; }

# Verified name-by-name against osv-scanner 2.4.0. A name NOT on this list must
# never reach `-L`: there is no per-file error recovery, the whole run aborts.
# Known-unsafe, do not add without re-verifying: go.sum, Cargo.toml, Gemfile,
# pubspec.yaml, pyproject.toml, package.json, Podfile.lock. The last one is not an
# oversight; osv-scanner has no CocoaPods extractor, so Podfile.lock is discovered
# for coverage accounting and reported as a permanent GAP.
lscan_ok() {
  case "$1" in
    Package.resolved|package-lock.json|yarn.lock|pnpm-lock.yaml|go.mod|Cargo.lock|\
poetry.lock|uv.lock|Gemfile.lock|composer.lock|pubspec.lock|requirements.txt) return 0 ;;
    *) return 1 ;;
  esac
}

# Absolute path from a scanner to repo-relative, symlink-normalized.
rel_path() {
  local r
  r=$(realpath "$1" 2>/dev/null) || r=$1
  case "$r" in
    "$root_phys"/*) printf '%s' "${r#"$root_phys"/}" ;;
    *) printf '%s' "$r" ;;
  esac
}

# --- Tier A: declared manifests and lockfiles ------------------------------
# Deliberately broad and still not exhaustive. Anything it misses falls through to
# Tier B rather than to "no manifests, nothing to audit", which is the failure this
# whole script exists to prevent. Lockfiles earn their place separately from
# manifests: a manifest says what is wanted, a lockfile says what is installed, and
# only the second is what a scanner can check.
SPECS=(
  "go.mod:go:manifest"                  "package.json:node:manifest"
  "Cargo.toml:rust:manifest"            "pyproject.toml:python:manifest"
  "requirements.txt:python:manifest"    "pubspec.yaml:dart:manifest"
  "Package.swift:swift:manifest"        "Gemfile:ruby:manifest"
  "composer.json:php:manifest"          ".tool-versions:asdf:manifest"
  ".nvmrc:node:manifest"                "mise.toml:mise:manifest"
  ".terraform.lock.hcl:terraform:manifest" "Dockerfile:container:manifest"
  "Package.resolved:swift:lock"         "package-lock.json:node:lock"
  "yarn.lock:node:lock"                 "pnpm-lock.yaml:node:lock"
  "Cargo.lock:rust:lock"                "poetry.lock:python:lock"
  "uv.lock:python:lock"                 "Gemfile.lock:ruby:lock"
  "composer.lock:php:lock"              "pubspec.lock:dart:lock"
  "go.sum:go:lock"                      "Podfile.lock:cocoapods:lock"
)

find_files() { find . \( "${PRUNE[@]}" \) -prune -o -type f -name "$1" -print 2>/dev/null; }

discover() {
  local spec name rest eco role f
  for spec in "${SPECS[@]}"; do
    name=${spec%%:*}; rest=${spec#*:}; eco=${rest%%:*}; role=${rest#*:}
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      f=${f#./}
      discovered+="$f	$eco	$role"$'\n'
    done < <(find_files "$name")
  done
}

# One `git check-ignore --stdin` for every discovered path, not one fork each.
compute_ignored() {
  [[ -z "$discovered" ]] && return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  ignored=$(cut -f1 <<<"$discovered" | git check-ignore --stdin 2>/dev/null)
  return 0
}

emit_manifests() {
  local f eco role track scanflag base
  while IFS=$'\t' read -r f eco role; do
    [[ -z "$f" ]] && continue
    base=${f##*/}
    if in_set "$f" "$ignored"; then track=gitignored; else track=tracked; fi
    if lscan_ok "$base"; then
      scanflag=scannable
      lock_targets+="$f"$'\n'
    else
      scanflag=discovery-only
    fi
    printf 'MANIFEST\t%s\t%s\t%s\t%s\t%s\n' "$f" "$eco" "$role" "$scanflag" "$track"
    n_manifest=$((n_manifest+1)); note_eco "$eco"
    emit_deps "$f" "$eco"
  done <<< "$discovered"
  return 0
}

# Direct dependencies and the runtime constraint. Transitive deps are the
# scanner's job, not this function's.
emit_deps() {
  local f="$1" eco="$2" line
  case "$eco" in
    go)
      [[ "$f" == *go.mod ]] || return 0
      # A require block contains blank lines and `// comment` lines as well as
      # requirements. The first version of this awk printed both as DEP rows
      # ("// a" and a bare space), because it filtered only on `// indirect`.
      # Requiring a second field that starts with `v` is what makes a line a
      # requirement rather than decoration.
      while IFS= read -r line; do
        printf 'DEP\t%s\t%s\t%s\n' "$f" "${line%% *}" "${line#* }"
        n_dep=$((n_dep+1))
      done < <(awk '/^require \(/{r=1;next} /^\)/{r=0}
                    r && $1 !~ /^(\/\/|$)/ && NF>=2 && $2 ~ /^v/ && !/\/\/ indirect/ {print $1" "$2}
                    /^require [^(]/ && $3 ~ /^v/ {print $2" "$3}' "$f" 2>/dev/null)
      line=$(awk '/^go [0-9]/{print $2; exit}' "$f" 2>/dev/null)
      [[ -n "$line" ]] && printf 'RUNTIME\t%s\tgo\t%s\n' "$f" "$line"
      ;;
    node)
      # A pinned Node version lives in .nvmrc as the whole file, and in
      # package.json under engines.node. Handling only the latter meant an
      # .nvmrc produced a MANIFEST record and no RUNTIME, so the pin this file
      # exists to express was invisible to the audit.
      if [[ "$f" == *.nvmrc ]]; then
        line=$(head -1 "$f" 2>/dev/null | tr -d ' \tv')
        [[ -n "$line" ]] && printf 'RUNTIME\t%s\tnode\t%s\n' "$f" "$line"
        return 0
      fi
      [[ "$f" == *package.json ]] || return 0
      while IFS=$'\t' read -r k v; do
        printf 'DEP\t%s\t%s\t%s\n' "$f" "$k" "$v"; n_dep=$((n_dep+1))
      done < <(jq -r '(.dependencies//{}) + (.devDependencies//{})
                      | to_entries[] | "\(.key)\t\(.value)"' "$f" 2>/dev/null)
      line=$(jq -r '.engines.node // empty' "$f" 2>/dev/null)
      [[ -n "$line" ]] && printf 'RUNTIME\t%s\tnode\t%s\n' "$f" "$line"
      ;;
    swift)
      # Only Package.resolved carries versions; Package.swift carries ranges and
      # is matched by the same ecosystem. Three schema generations are in the
      # wild and all three appear under ~/dev: v1 nests under `object.pins`,
      # v2 and v3 use a top-level `pins`. A pin can also be branch- or
      # revision-based, with no version at all.
      [[ "$f" == *Package.resolved ]] || return 0
      while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        printf 'DEP\t%s\t%s\t%s\n' "$f" "$k" "$v"; n_dep=$((n_dep+1))
      done < <(jq -r '(.pins // .object.pins // [])[]
                      | "\(.identity // .package)\t\(.state.version // .state.branch // .state.revision // "unpinned")"' \
                    "$f" 2>/dev/null)
      ;;
    asdf|mise)
      # `.tool-versions` and mise.toml pin runtimes for several ecosystems at
      # once, one per line. Emit each as a RUNTIME rather than dropping the file.
      while read -r tool ver _; do
        [[ -z "$tool" || "$tool" == \#* ]] && continue
        printf 'RUNTIME\t%s\t%s\t%s\n' "$f" "$tool" "${ver//\"/}"
      done < <(grep -vE '^\s*(#|\[|$)' "$f" 2>/dev/null | tr -d "'" | sed 's/=/ /')
      ;;
  esac
  return 0
}

# --- Tier B: version-bearing references outside manifests ------------------
# The tier that makes this pass work on doc, prompt, and IaC repos, whose
# versions live in runtime enums and model IDs and never in a manifest.
REF_PATTERN='NODEJS_[0-9]+_X|provided\.al[0-9]+|python3\.[0-9]+|(claude|gemini)-[a-z0-9.-]*[0-9]|amazon\.nova[a-z0-9.:-]*|openai\.gpt-[0-9.]+|uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+|FROM [A-Za-z0-9_./-]+:[A-Za-z0-9_.-]+|anthropic-version: *[0-9-]+|swift-tools-version:? *[0-9.]+'

emit_refs() {
  local hit file lineno text ident total tmp
  tmp=$(mktemp) || return 0
  # -I skips binary files, and it is not a micro-optimization: without it this
  # grep read regist's 13GB of build artifacts and took 37 of the script's 42
  # seconds. With it, 1 second. The --exclude-dir list mirrors PRUNE; when the two
  # drifted apart, iOS and Flutter repos walked DerivedData and Pods here while
  # find skipped them.
  grep -rnIE "$REF_PATTERN" . \
    --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
    --exclude-dir=target --exclude-dir=build --exclude-dir=dist \
    --exclude-dir=.next --exclude-dir=cdk.out --exclude-dir=DerivedData \
    --exclude-dir=Pods --exclude-dir=.build --exclude-dir=.dart_tool \
    > "$tmp" 2>/dev/null
  total=$(wc -l < "$tmp" | tr -d ' ')
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file=${hit%%:*}; hit=${hit#*:}
    lineno=${hit%%:*}; text=${hit#*:}
    ident=$(printf '%s' "$text" | grep -oE "$REF_PATTERN" | head -1)
    [[ -z "$ident" ]] && continue
    # Squeeze whitespace so one record stays one line.
    text=$(printf '%s' "$text" | tr '\t' ' ' | sed 's/^ *//;s/ *$//' | cut -c1-120)
    printf 'REF\t%s:%s\t%s\t%s\n' "${file#./}" "$lineno" "$ident" "$text"
    n_ref=$((n_ref+1))
  done < <(head -"$REF_CAP" "$tmp")
  # A cap that does not announce itself is a silent claim of completeness. On
  # regist this drops 11 records and on sophie 39, and both used to vanish.
  if [[ "$total" -gt "$REF_CAP" ]]; then
    printf 'NOTE\tref-cap\tshowing %s of %s version-bearing references, %s dropped at the cap\n' \
      "$REF_CAP" "$total" "$((total - REF_CAP))"
  fi
  rm -f "$tmp"
  return 0
}

# --- Tier C: undeclared hard prerequisites ---------------------------------
# Only binaries the project's OWN entrypoints invoke. POSIX utilities are not
# findings. Read what runs, not what strings mention: a file-extension literal
# inside a classifier is not a dependency.
emit_prereqs() {
  local b
  for b in jq yq gh aws gcloud docker osv-scanner govulncheck cwebp ffmpeg; do
    if grep -rqE "(^|[^A-Za-z0-9_-])$b " Makefile justfile Taskfile.y*ml \
         .github/workflows/*.y*ml scripts/*.sh 2>/dev/null; then
      command -v "$b" >/dev/null 2>&1 \
        && printf 'PREREQ\t%s\tinvoked by project entrypoints, present\n' "$b" \
        || printf 'PREREQ\t%s\tinvoked by project entrypoints, NOT INSTALLED\n' "$b"
      n_prereq=$((n_prereq+1))
    fi
  done
  return 0
}

# --- Security scan ---------------------------------------------------------
# Never report "clean" because no scanner was installed. That is the one result
# here that would be actively misleading, and COVERAGE below generalizes it.
#
# One SCAN record per output line, never a truncated-and-flattened summary. The
# first version piped through `tail -5 | tr '\n' ' '`, which on a real repo cut
# the vulnerability table off mid-row and ran the survivors together: it dropped
# findings and mangled the ones it kept, on the single most important output this
# script produces. Volume is not a reason to truncate a CVE list.

# Pull the coverage evidence out of a scanner's own progress output. In table mode
# osv-scanner writes progress and results both to stdout, so this reads the same
# capture the findings come from.
record_scanned() {
  local tool="$1" out="$2" line p r eco
  while IFS= read -r line; do
    case "$line" in "Scanned "*" file and found "*) ;; *) continue ;; esac
    p=${line#Scanned }; p=${p%% file and found *}
    r=$(rel_path "$p")
    # osv-scanner walks .git and reports git-lfs bookkeeping files as scanned
    # sources. They are not dependencies and must not count as coverage.
    case "$r" in .git/*|*/.git/*) continue ;; esac
    in_set "$r" "$scanned" && continue
    scanned+="$r"$'\n'
    printf 'SCANNED\t%s\t%s\n' "$r" "$tool"
    eco=$(awk -F'\t' -v want="$r" '$1==want{print $2; exit}' <<<"$discovered")
    [[ -n "$eco" ]] && note_seco "$eco"
  done <<< "$out"
  return 0
}

# Keep only lines carrying a vulnerability identifier or an explicit verdict, so
# the record count reflects findings rather than table borders. The previous
# regex included `found 0`, meant to catch npm audit's "found 0 vulnerabilities";
# what it actually matched was osv-scanner's "Scanned <.git/lfs/...> and found 0
# packages", so the output carried four lines of git bookkeeping and not one line
# of real coverage. Coverage is SCANNED's job now, and this filter drops it.
emit_scan_lines() {
  local tool="$1" out="$2" line kept=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in "Scanned "*|"Scanning "*|"Starting filesystem walk"*|"End status:"*) continue ;; esac
    if [[ "$line" =~ (CVE-|GHSA-|GO-[0-9]{4}-|OSV-|[Vv]ulnerabilit|No\ issues|no\ vulnerabilities) ]]; then
      printf 'SCAN\t%s\t%s\n' "$tool" "$(printf '%s' "$line" | tr -s ' \t' ' ' | sed 's/^ *//;s/ *$//')"
      kept=$((kept+1))
    fi
  done <<< "$out"
  [[ "$kept" == 0 ]] && printf 'SCAN\t%s\tran, no vulnerability lines matched; check manually if this looks wrong\n' "$tool"
  return 0
}

# Collapse the advisory table into the upgrades that close it. osv-scanner already
# resolved which fixed version applies to each installed version, which is the part
# that is genuinely hard, so this groups its answer rather than recomputing it.
emit_fixes() {
  local out="$1"
  awk -F'|' '
    /^\|/ && $2 ~ /osv\.dev/ {
      for (i = 2; i <= 8; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
      pkg = $5; sub(/ *\(dev\)$/, "", pkg)
      key = $8 SUBSEP pkg SUBSEP $6
      n[key]++
      if (fixed[key] == "" || cmpv($7, fixed[key]) > 0) fixed[key] = $7
      if ($3 + 0 > cvss[key] + 0) cvss[key] = $3
      src[key] = $8; name[key] = pkg; cur[key] = $6
      dev[key] = ($5 ~ /\(dev\)$/) ? " (dev)" : ""
    }
    function cmpv(a, b,   x, y, i, m) {
      split(a, x, "."); split(b, y, ".")
      m = (length(x) > length(y)) ? length(x) : length(y)
      for (i = 1; i <= m; i++) { if ((x[i]+0) != (y[i]+0)) return (x[i]+0) - (y[i]+0) }
      return 0
    }
    END {
      for (k in n)
        printf "FIX\t%s\t%s%s\t%s\t%s\t%d\t%s\n", src[k], name[k], dev[k], cur[k], fixed[k], n[k], cvss[k]
    }
  ' <<< "$out" | sort -t"$(printf '\t')" -k7,7nr -k6,6nr
  return 0
}

run_osv_pass2() {
  local list="$1" out args_shown=0
  local -a args
  args=()
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    args+=( -L "$p" )
    args_shown=$((args_shown+1))
  done <<< "$list"
  [[ "$args_shown" == 0 ]] && return 0
  out=$(osv-scanner "${args[@]}" 2>&1)
  # 127 here is NOT "command not found": osv-scanner uses it for an unextractable
  # -L path, and one such path aborts the whole invocation. lscan_ok should make
  # that unreachable, so if it happens the allowlist is wrong and the honest
  # output is a gap, not a silent partial result.
  if [[ $? -eq 127 ]] || printf '%s' "$out" | grep -q "could not determine extractor"; then
    printf 'NOTE\tpass2-aborted\t%s\n' \
      "$(printf '%s' "$out" | grep 'could not determine extractor' | head -1 | tr -s ' \t' ' ')"
    return 0
  fi
  record_scanned osv-scanner "$out"
  emit_scan_lines osv-scanner "$out"
  emit_fixes "$out"
  return 0
}

emit_scan() {
  local tool="" out="" pending=""
  if command -v osv-scanner >/dev/null 2>&1; then
    tool=osv-scanner
    out=$(osv-scanner -r . 2>&1)
    record_scanned "$tool" "$out"
    emit_scan_lines "$tool" "$out"
    emit_fixes "$out"
    # Pass 2: everything discovery found and pass 1 did not read. Empty on a repo
    # that hides nothing, which is the common case and costs nothing.
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      in_set "$p" "$scanned" && continue
      pending+="$p"$'\n'
    done <<< "$lock_targets"
    [[ -n "${pending//[[:space:]]/}" ]] && run_osv_pass2 "$pending"
    return 0
  fi

  if command -v govulncheck >/dev/null 2>&1 && [[ -f go.mod ]]; then
    tool=govulncheck; out=$(govulncheck ./... 2>&1)
    note_seco go
  elif [[ -f package.json ]] && command -v npm >/dev/null 2>&1; then
    tool=npm-audit; out=$(npm audit 2>&1)
    note_seco node
  else
    printf 'SCAN\tnone\tunavailable: install osv-scanner (do NOT report clean)\n'
    return 0
  fi
  emit_scan_lines "$tool" "$out"
  return 0
}

# --- Coverage cross-check --------------------------------------------------
# The whole point. Every ecosystem discovery found gets a verdict, and a GAP has
# to say WHY, because "swift: GAP" with no cause is the same unfalsifiable claim
# this record exists to replace.
emit_coverage() {
  local eco why n_ignored n_lock
  for eco in $ecosystems; do
    case " $scanned_ecos " in
      *" $eco "*) printf 'COVERAGE\t%s\tcovered\tscanned by a vulnerability scanner\n' "$eco"; continue ;;
    esac
    n_gap=$((n_gap+1))
    if ! command -v osv-scanner >/dev/null 2>&1; then
      why="no osv-scanner installed; the fallback scanner covers one ecosystem only"
    else
      n_lock=$(awk -F'\t' -v e="$eco" '$2==e && $3=="lock"' <<<"$discovered" | wc -l | tr -d ' ')
      if [[ "$n_lock" == 0 ]]; then
        why="no lockfile found for this ecosystem; only a manifest, which pins nothing"
      else
        n_ignored=$(awk -F'\t' -v e="$eco" '$2==e && $3=="lock"{print $1}' <<<"$discovered" \
                    | while IFS= read -r p; do in_set "$p" "$ignored" && echo x; done | wc -l | tr -d ' ')
        if [[ "$n_ignored" != 0 ]]; then
          why="lockfile present but gitignored and no extractor accepted it"
        else
          why="lockfile present but no scanner extractor supports this ecosystem"
        fi
      fi
    fi
    printf 'COVERAGE\t%s\tGAP\t%s\n' "$eco" "$why"
  done
  return 0
}

if [[ "$scan_only" == 0 ]]; then
  discover
  compute_ignored
  emit_manifests
  emit_refs
  emit_prereqs
fi
emit_scan
[[ "$scan_only" == 0 ]] && emit_coverage

n_files=$(find . \( "${PRUNE[@]}" \) -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')
n_eco=$(printf '%s' "$ecosystems" | wc -w | tr -d ' ')
n_seco=$(printf '%s' "$scanned_ecos" | wc -w | tr -d ' ')
printf 'SUMMARY\tfiles=%s ecosystems=%s scanned_ecosystems=%s coverage_gaps=%s manifests=%s deps=%s refs=%s prereqs=%s\n' \
  "$n_files" "$n_eco" "$n_seco" "$n_gap" "$n_manifest" "$n_dep" "$n_ref" "$n_prereq"
