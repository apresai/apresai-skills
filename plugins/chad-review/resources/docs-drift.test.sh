#!/usr/bin/env bash
# docs-drift.test.sh: suite for docs-drift.sh.
#
# WHY THIS EXISTS
# Three documentation-drift shapes shipped on a real repo and survived review:
# a plan doc gained an "EXECUTION COMPLETE ... historical execution record"
# banner while still saying "**Status:** Active plan" and "the working master
# plan"; a device checklist said "target build 117/118 or later" while the
# tracked BUILD_NUMBER read 152; and an index classified a doc as superseded
# while the doc called itself active. Every fixture here is a synthetic replay
# of one of those shapes, or of a suppression that must NOT fire (labeled
# history is history, not drift). Fixture em-dashes are emitted as bytes so
# this source file stays ASCII for the repo prose gate.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docs-drift.sh"
pass=0; fail=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <desc> <expected-substring> <actual>
  if grep -qF "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}
absent(){ # absent <desc> <substring-that-must-not-appear> <actual>
  if grep -qF "$2" <<<"$3"; then
    bad "$1"; printf '       must NOT contain: %s\n' "$2"
  else ok "$1"; fi
}

newrepo(){ d=$(mktemp -d); ( cd "$d" && git init -q . ); echo "$d"; }
run(){ ( cd "$1" && shift && bash "$SCRIPT" "$@" 2>&1 ); }

# The incident shape: banner on line 1, Active status on line 5, working-plan
# self-description on line 12, live imperative section below.
mkplan() {
  cat > "$1" <<'EOF'
> EXECUTION COMPLETE (2026-06-12). This is the historical execution record.

Header padding.

**Status:** Active plan and validation register.

More padding.
More padding.
More padding.
More padding.
More padding.
This document is the working master plan for release-hardening work.

## How to Use This Plan

1. Pick the highest open group from the queue below.
2. Re-check each finding against the current code before editing.
EOF
}

# --- 1. banner + Active + working-plan language: the status conflict ---------
r=$(newrepo)
mkplan "$r/plan.md"
out=$(run "$r")
check "status conflict reported" "$(printf 'CONTRA\tplan.md\tstatus-conflict\t1:5')" "$out"
check "hist marker carries the banner" "$(printf '\thist\t')" "$out"
check "active marker carries the status line" "$(printf '\tactive\t')" "$out"
check "conflict quotes both sides" "historical execution record. => **Status:** Active plan" "$out"
rm -rf "$r"

# --- 2. correctly labeled historical report: old floor is history ------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
cat > "$r/report.md" <<'EOF'
> This is the historical execution record of the June validation run.

The run targeted build 117 or later and completed on every device.
EOF
out=$(run "$r")
absent "labeled history is never a conflict" "CONTRA" "$out"
absent "a floor inside labeled history is never stale" "STALE" "$out"
check "the clean file is a positive record" "$(printf 'OKDOC\treport.md')" "$out"
rm -rf "$r"

# --- 3. live checklist floor vs tracked BUILD_NUMBER --------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
cat > "$r/checklist.md" <<'EOF'
# Device checklist

- [ ] Run on the device (target build 117/118 or later).
EOF
out=$(run "$r")
check "authority discovered" "$(printf 'AUTHORITY\tBUILD_NUMBER\tbuild\t152')" "$out"
check "stale floor carries floor, authority, source" "$(printf '\t118\t152\tBUILD_NUMBER\t')" "$out"
check "stale record names the doc line" "$(printf 'STALE\tchecklist.md:3')" "$out"
rm -rf "$r"

# --- 4. the 131+ floor form ----------------------------------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Checklist\n\nThe session requires build 131+ on the device.\n' > "$r/checklist.md"
out=$(run "$r")
check "N+ floors compare too" "$(printf '\t131\t152\tBUILD_NUMBER\t')" "$out"
rm -rf "$r"

# --- 5. canonical reference is the drift-resistant shape ----------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
cat > "$r/checklist.md" <<'EOF'
# Device checklist

Target build: see BUILD_NUMBER at the repo root.
Install build `$(cat BUILD_NUMBER)` or later before starting.
EOF
out=$(run "$r")
check "authority reference is a canonical marker" "$(printf '\tcanonical\t')" "$out"
absent "a canonical reference is never stale" "STALE" "$out"
rm -rf "$r"

# --- 6. historical sections and dated evidence are preserved ------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
cat > "$r/notes.md" <<'EOF'
# Live notes

Status: current notes for the device team.
The reviewer bounced 6 times on build 131+ (session of 2026-06-12).

## Historical snapshot

At the time we required build 118 or later.
EOF
out=$(run "$r")
absent "dated evidence and history sections never go stale" "STALE" "$out"
rm -rf "$r"

# --- 7. wholly-historical file with a floor and no active markers -------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
cat > "$r/old-plan.md" <<'EOF'
> Superseded by plan-v2.md. Archived.

Devices needed build 117 or later for this plan.
EOF
out=$(run "$r")
absent "a wholly-historical file never goes stale" "STALE" "$out"
rm -rf "$r"

# --- 8. floors at or above the authority are fine ------------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Checklist\n\nUse build 152 or later.\nOr any build 160+.\n' > "$r/checklist.md"
out=$(run "$r")
absent "current floors are not stale" "STALE" "$out"
rm -rf "$r"

# --- 9. Makefile BUILD_NUM as the authority ------------------------------------
r=$(newrepo)
printf 'BUILD_NUM := 152\n\nall:\n\ttrue\n' > "$r/Makefile"
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
out=$(run "$r")
check "Makefile variable is an authority" "$(printf 'AUTHORITY\tMakefile\tbuild\t152')" "$out"
check "floor compares against the Makefile value" "$(printf '\t117\t152\tMakefile\t')" "$out"
rm -rf "$r"

# --- 10. Makefile $(shell cat FILE) resolves through the file -------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf 'BUILD_NUM := $(shell cat BUILD_NUMBER)\n\nall:\n\ttrue\n' > "$r/Makefile"
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
out=$(run "$r")
check "shell-cat authority resolves to the scalar" "$(printf 'AUTHORITY\tMakefile\tbuild\t152')" "$out"
rm -rf "$r"

# --- 11. pbxproj authority: one row, the max value ------------------------------
r=$(newrepo)
mkdir -p "$r/ios/App.xcodeproj"
cat > "$r/ios/App.xcodeproj/project.pbxproj" <<'EOF'
		CURRENT_PROJECT_VERSION = 152;
		CURRENT_PROJECT_VERSION = 152;
EOF
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
out=$(run "$r")
check "pbxproj is an authority" "$(printf 'AUTHORITY\tios/App.xcodeproj/project.pbxproj\tbuild\t152')" "$out"
n=$(grep -c 'project.pbxproj' <<<"$out")
if [[ "$n" == "2" ]]; then ok "one AUTHORITY row per pbxproj (plus its STALE citation)"; else bad "one AUTHORITY row per pbxproj (got $n rows)"; fi
rm -rf "$r"

# --- 12. semver authority and version floors ------------------------------------
r=$(newrepo)
printf '{"name":"x","version":"3.2.1"}\n' > "$r/package.json"
printf '# Setup\n\nRequires version 1.2.0 or later of the CLI.\n' > "$r/setup.md"
out=$(run "$r")
check "package.json is a version authority" "$(printf 'AUTHORITY\tpackage.json\tversion\t3.2.1')" "$out"
check "semver floors compare dotted-numerically" "$(printf '\t1.2.0\t3.2.1\tpackage.json\t')" "$out"
rm -rf "$r"

# --- 13. no authority means no guess, said out loud -----------------------------
r=$(newrepo)
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
out=$(run "$r")
absent "staleness is never guessed without an authority" "STALE" "$out"
check "the gap is announced" "no-authority" "$out"
rm -rf "$r"

# --- 14. index says superseded, doc says Active ----------------------------------
r=$(newrepo)
mkdir -p "$r/docs"
printf 'plan.md is superseded by plan-v2.md.\n' > "$r/docs/INDEX.md"
printf '# Plan\n\nStatus: Active plan.\n' > "$r/plan.md"
out=$(run "$r" -- plan.md)
check "the index classification is a record" "$(printf 'INDEXED\tdocs/INDEX.md:1\tplan.md\thistorical')" "$out"
check "index disagreement is a conflict" "$(printf 'CONTRA\tplan.md\tindex-conflict\tdocs/INDEX.md:1\tlive-vs-historical')" "$out"
rm -rf "$r"

# --- 15. index agreeing with the doc is evidence, not a conflict -----------------
r=$(newrepo)
mkdir -p "$r/docs"
printf 'plan.md is the historical record of the June run.\n' > "$r/docs/INDEX.md"
printf '> This is the historical execution record.\n\nDone.\n' > "$r/plan.md"
out=$(run "$r" -- plan.md)
check "agreeing index still emits INDEXED" "$(printf 'INDEXED\tdocs/INDEX.md:1\tplan.md\thistorical')" "$out"
absent "agreement is not a conflict" "CONTRA" "$out"
rm -rf "$r"

# --- 16. the reverse conflict: index says live, doc says historical --------------
r=$(newrepo)
printf 'The single live backlog is plan.md.\n' > "$r/README.md"
printf '> EXECUTION COMPLETE. This is the historical execution record.\n\nDone.\n' > "$r/plan.md"
out=$(run "$r" -- plan.md)
check "reverse disagreement is a conflict" "$(printf 'CONTRA\tplan.md\tindex-conflict\tREADME.md:1\thistorical-vs-live')" "$out"
rm -rf "$r"

# --- 17. explicit argv scope wins over discovery ---------------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# A\n\nTarget build 117 or later.\n' > "$r/a.md"
printf '# B\n\nTarget build 118 or later.\n' > "$r/b.md"
out=$(run "$r" -- a.md)
check "the passed doc is scanned" "$(printf 'STALE\ta.md:3')" "$out"
absent "the unpassed doc is not" "b.md" "$out"
rm -rf "$r"

# --- 18. bare invocation discovers untracked docs --------------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
out=$(run "$r")
check "untracked docs are discovered" "$(printf 'STALE\tchecklist.md:3')" "$out"
rm -rf "$r"

# --- 19. --last-commit discovers from HEAD ---------------------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
printf '# Checklist\n\nTarget build 117 or later.\n' > "$r/checklist.md"
( cd "$r" && git add -A && git commit -qm init )
out=$(run "$r" --last-commit)
check "last-commit mode scans the committed doc" "$(printf 'STALE\tchecklist.md:3')" "$out"
rm -rf "$r"

# --- 20. binary and non-markdown scope entries are skips, not crashes -------------
r=$(newrepo)
printf '\x00\x01\x02' > "$r/x.md"
printf 'plain\n' > "$r/y.txt"
out=$(run "$r" -- x.md y.txt)
check "binary md is a skip" "$(printf 'SKIP\tx.md\tbinary')" "$out"
check "non-markdown scope entry is a skip" "$(printf 'SKIP\ty.txt\tnot-markdown')" "$out"
rm -rf "$r"

# --- 21. outside a git repo, argv still works -------------------------------------
d=$(mktemp -d)
printf '152\n' > "$d/BUILD_NUMBER"
printf '# Checklist\n\nTarget build 117 or later.\n' > "$d/checklist.md"
out=$(run "$d" -- checklist.md)
check "non-git dir still scans explicit docs" "$(printf 'STALE\tchecklist.md:3')" "$out"
check "summary still prints" "SUMMARY" "$out"
rm -rf "$d"

# --- 22. exit 0 with findings -------------------------------------------------------
r=$(newrepo)
mkplan "$r/plan.md"
( cd "$r" && bash "$SCRIPT" >/dev/null 2>&1 )
code=$?
if [[ "$code" == "0" ]]; then ok "exit 0 despite findings"; else bad "exit 0 despite findings (got $code)"; fi
rm -rf "$r"

# --- 23. a clean ordinary doc is prose with a positive record ----------------------
r=$(newrepo)
printf 'Just a readme.\n\nNothing to see.\n' > "$r/README.md"
out=$(run "$r")
check "ordinary prose is classified prose" "$(printf 'DOC\tREADME.md\tprose')" "$out"
check "clean doc gets OKDOC" "$(printf 'OKDOC\tREADME.md')" "$out"
check "summary shows zero findings" "stale=0" "$out"
rm -rf "$r"

# --- 24. the line cap announces itself ----------------------------------------------
r=$(newrepo)
awk 'BEGIN { for (i = 0; i < 6000; i++) print "filler prose line " i }' > "$r/big.md"
out=$(run "$r")
check "over-cap docs announce the cut" "line-cap" "$out"
rm -rf "$r"

# --- 25. an em-dash on the flagged line survives the pipeline ------------------------
r=$(newrepo)
printf '152\n' > "$r/BUILD_NUMBER"
{ printf '# Checklist\n\n'
  printf 'Target build 117 or later \xe2\x80\x94 confirm on the device first.\n'
} > "$r/checklist.md"
out=$(run "$r")
check "em-dash line still yields the stale record" "$(printf 'STALE\tchecklist.md:3\t117\t152\tBUILD_NUMBER')" "$out"
rm -rf "$r"

# --- 26. the neighbor cap announces itself -------------------------------------------
r=$(newrepo)
printf '# Plan\n\nStatus: Active plan.\n' > "$r/plan.md"
i=1; while [[ $i -le 25 ]]; do printf 'See plan.md for details.\n' > "$r/ref$i.md"; i=$((i+1)); done
out=$(run "$r" -- plan.md)
check "too many neighbors announce the cap" "neighbor-cap" "$out"
rm -rf "$r"

echo
echo "docs-drift.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
