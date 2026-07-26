#!/usr/bin/env bash
# freshness.sh: everything pass 5 can determine without judgment.
#
# WHY THIS IS A SCRIPT
# Finding manifests, reading pinned versions, spotting version-bearing strings in
# files that are not manifests, and running a vulnerability scanner are all
# deterministic. They were 80 lines of English asking a model to run greps and
# hash files. What a model still has to decide is whether a gap is worth taking
# now and whether a version string in prose is a prescription or a warning. That
# judgment stays in the skill; everything mechanical is here.
#
# The same reasoning that made chad-review-route.sh a script rather than a
# paragraph. A script's conditions cannot silently disagree with the prose around
# them, because there is no prose around them.
#
# USAGE
#   bash freshness.sh              # audit the repo containing $PWD
#   bash freshness.sh --scan-only  # skip discovery, just run the vuln scanner
#
# OUTPUT
# Labeled blocks on stdout, one record per line, tab-separated. Empty blocks are
# omitted. The SUMMARY line always prints, so "nothing found" arrives with counts
# behind it rather than as an unfalsifiable claim.
#
#   MANIFEST  <path>            <ecosystem>
#   DEP       <manifest>        <name>        <pinned>
#   RUNTIME   <manifest>        <name>        <constraint>
#   REF       <file>:<line>     <identifier>  <surrounding line>
#   PREREQ    <binary>          <where it is required>
#   SCAN      <tool>            <result>
#   SUMMARY   files=N ecosystems=M manifests=X deps=Y refs=Z prereqs=P
#
# REF records carry their surrounding line ON PURPOSE. `NODEJS_20_X reached EOL`
# is a correct warning, not a finding, and only the context distinguishes it from
# a prescription. Stripping it here would force the judgment step to guess.
#
# EXIT: 0 whenever the audit ran. Findings are data, not failure. Non-zero means
# the script itself broke, which is the only thing a caller should treat as an
# error.
set -uo pipefail

scan_only=0
[[ "${1:-}" == "--scan-only" ]] && scan_only=1

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || exit 1

PRUNE=( -name node_modules -o -name .git -o -name vendor -o -name target
        -o -name build -o -name dist -o -name .next -o -name cdk.out
        -o -name DerivedData -o -name Pods -o -name .build -o -name .dart_tool )

n_manifest=0; n_dep=0; n_ref=0; n_prereq=0; ecosystems=""

note_eco() { case " $ecosystems " in *" $1 "*) ;; *) ecosystems+="$1 " ;; esac; }

# --- Tier A: declared manifests -------------------------------------------
# The list is deliberately broad and still not exhaustive. Anything it misses
# falls through to Tier B rather than to "no manifests, nothing to audit", which
# is the failure this whole script exists to prevent.
find_files() { find . \( "${PRUNE[@]}" \) -prune -o -type f -name "$1" -print 2>/dev/null; }

emit_manifests() {
  local f eco
  for spec in \
    "go.mod:go" "package.json:node" "Cargo.toml:rust" "pyproject.toml:python" \
    "requirements.txt:python" "pubspec.yaml:dart" "Package.swift:swift" \
    "Gemfile:ruby" "composer.json:php" ".tool-versions:asdf" ".nvmrc:node" \
    "mise.toml:mise" "Podfile.lock:cocoapods" ".terraform.lock.hcl:terraform" \
    "Dockerfile:container"; do
    eco=${spec##*:}
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      f=${f#./}
      printf 'MANIFEST\t%s\t%s\n' "$f" "$eco"
      n_manifest=$((n_manifest+1)); note_eco "$eco"
      emit_deps "$f" "$eco"
    done < <(find_files "${spec%%:*}")
  done
}

# Direct dependencies and the runtime constraint. Transitive deps are the
# scanner's job, not this function's.
emit_deps() {
  local f="$1" eco="$2" line
  case "$eco" in
    go)
      while IFS= read -r line; do
        printf 'DEP\t%s\t%s\t%s\n' "$f" "$(awk '{print $1}' <<<"$line")" "$(awk '{print $2}' <<<"$line")"
        n_dep=$((n_dep+1))
      done < <(awk '/^require \(/{r=1;next} /^\)/{r=0} r&&!/\/\/ indirect/{print $1" "$2}
                    /^require [^(]/{print $2" "$3}' "$f" 2>/dev/null)
      line=$(awk '/^go [0-9]/{print $2; exit}' "$f" 2>/dev/null)
      [[ -n "$line" ]] && printf 'RUNTIME\t%s\tgo\t%s\n' "$f" "$line"
      ;;
    node)
      [[ "$f" == *package.json ]] || return 0
      while IFS=$'\t' read -r k v; do
        printf 'DEP\t%s\t%s\t%s\n' "$f" "$k" "$v"; n_dep=$((n_dep+1))
      done < <(jq -r '(.dependencies//{}) + (.devDependencies//{})
                      | to_entries[] | "\(.key)\t\(.value)"' "$f" 2>/dev/null)
      line=$(jq -r '.engines.node // empty' "$f" 2>/dev/null)
      [[ -n "$line" ]] && printf 'RUNTIME\t%s\tnode\t%s\n' "$f" "$line"
      ;;
  esac
  return 0
}

# --- Tier B: version-bearing references outside manifests ------------------
# The tier that makes this pass work on doc, prompt, and IaC repos, whose
# versions live in runtime enums and model IDs and never in a manifest.
REF_PATTERN='NODEJS_[0-9]+_X|provided\.al[0-9]+|python3\.[0-9]+|(claude|gemini)-[a-z0-9.-]*[0-9]|amazon\.nova[a-z0-9.:-]*|openai\.gpt-[0-9.]+|uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+|FROM [A-Za-z0-9_./-]+:[A-Za-z0-9_.-]+|anthropic-version: *[0-9-]+|swift-tools-version:? *[0-9.]+'

emit_refs() {
  local hit file lineno text ident
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file=${hit%%:*}; hit=${hit#*:}
    lineno=${hit%%:*}; text=${hit#*:}
    ident=$(grep -oE "$REF_PATTERN" <<<"$text" | head -1)
    [[ -z "$ident" ]] && continue
    # Squeeze whitespace so one record stays one line.
    text=$(tr '\t' ' ' <<<"$text" | sed 's/^ *//;s/ *$//' | cut -c1-120)
    printf 'REF\t%s:%s\t%s\t%s\n' "${file#./}" "$lineno" "$ident" "$text"
    n_ref=$((n_ref+1))
  done < <(grep -rnE "$REF_PATTERN" . \
             --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
             --exclude-dir=build --exclude-dir=dist --exclude-dir=.next \
             --exclude-dir=cdk.out --exclude-dir=target 2>/dev/null | head -200)
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
# here that would be actively misleading.
emit_scan() {
  if command -v osv-scanner >/dev/null 2>&1; then
    printf 'SCAN\tosv-scanner\t%s\n' "$(osv-scanner -r . 2>&1 | tail -5 | tr '\n' ' ')"
  elif command -v govulncheck >/dev/null 2>&1 && [[ -f go.mod ]]; then
    printf 'SCAN\tgovulncheck\t%s\n' "$(govulncheck ./... 2>&1 | tail -5 | tr '\n' ' ')"
  elif [[ -f package.json ]] && command -v npm >/dev/null 2>&1; then
    printf 'SCAN\tnpm-audit\t%s\n' "$(npm audit --json 2>/dev/null | jq -c '.metadata.vulnerabilities // "unreadable"' 2>/dev/null)"
  else
    printf 'SCAN\tnone\tunavailable: install osv-scanner (do NOT report clean)\n'
  fi
  return 0
}

if [[ "$scan_only" == 0 ]]; then
  emit_manifests
  emit_refs
  emit_prereqs
fi
emit_scan

n_files=$(find . \( "${PRUNE[@]}" \) -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')
n_eco=$(wc -w <<<"$ecosystems" | tr -d ' ')
printf 'SUMMARY\tfiles=%s ecosystems=%s manifests=%s deps=%s refs=%s prereqs=%s\n' \
  "$n_files" "$n_eco" "$n_manifest" "$n_dep" "$n_ref" "$n_prereq"
