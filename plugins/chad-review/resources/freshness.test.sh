#!/usr/bin/env bash
# freshness.test.sh: suite for freshness.sh.
#
# WHY THIS EXISTS
# freshness.sh replaced 80 lines of prose that asked a model to run greps. Prose
# cannot be tested; this can, and it needs to be: hand-testing the script against
# two real repos found two bugs within minutes of writing it (a go.mod require
# block emitting its blank and comment lines as dependencies, and an .nvmrc that
# produced a MANIFEST record with no RUNTIME, so the pin the file exists to
# express was invisible). Both are locked down below.
#
# Every case builds a throwaway repo under a temp dir. Nothing here touches the
# repo it ships in.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/freshness.sh"
pass=0; fail=0

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
run(){ ( cd "$1" && bash "$SCRIPT" 2>&1 ); }

# A stub osv-scanner, so coverage can be asserted with no network and whether or
# not the real scanner is installed. `make validate` runs this suite in both
# conditions, and coverage is the one property that cannot be checked by asking
# the real tool: the whole point is what it did NOT look at.
#
# It replays the shape of real output rather than a fixed transcript, keyed off
# the same two facts the script reads: which paths a pass claims to have scanned,
# and the advisory table. Pass 1 (directory walk) reports OSV_STUB_SCANNED. Pass 2
# (-L) reports exactly the paths it was handed, which is what makes the
# discovered-minus-scanned diff observable from outside.
mkstub(){
  mkdir -p "$1/.stub"
  cat > "$1/.stub/osv-scanner" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *-L* ]]; then
  prev=""
  for a in "$@"; do
    [[ "$prev" == "-L" ]] && echo "Scanned $PWD/$a file and found 1 package"
    prev=$a
  done
  echo "No issues found"
else
  for p in ${OSV_STUB_SCANNED:-}; do
    echo "Scanned $PWD/$p file and found 1 package"
  done
  # A verdict line, always. The real tool prints one whenever its query returned,
  # and the script now requires it before crediting coverage, because a Scanned
  # line proves only that a file was read.
  if [[ -n "${OSV_STUB_TABLE:-}" && -f "${OSV_STUB_TABLE:-}" ]]; then
    cat "$OSV_STUB_TABLE"
  else
    echo "No issues found"
  fi
fi
exit 0
STUB
  chmod +x "$1/.stub/osv-scanner"
}
# PATH is scoped to this one invocation; nothing is installed outside the temp dir.
runstub(){ # runstub <repo> <paths pass 1 scanned> [advisory table file]
  ( cd "$1" && PATH="$1/.stub:$PATH" OSV_STUB_SCANNED="$2" OSV_STUB_TABLE="${3:-}" \
      bash "$SCRIPT" 2>&1 )
}

echo "freshness.sh suite"

# --- go.mod ---------------------------------------------------------------
r=$(newrepo)
printf 'module example.com/x\n\ngo 1.26\n\nrequire (\n\t// a comment line\n\n\tgithub.com/a/b v1.0.0\n\tgithub.com/c/d v2.0.0 // indirect\n)\n' > "$r/go.mod"
out=$(run "$r")
check   "go.mod detected"                 "MANIFEST	go.mod	go"            "$out"
check   "direct dep extracted"            "DEP	go.mod	github.com/a/b	v1.0.0" "$out"
absent  "indirect dep skipped"            "github.com/c/d"                  "$out"
absent  "comment line is not a dep"       "// a comment"                    "$out"
check   "go directive is a RUNTIME"       "RUNTIME	go.mod	go	1.26"          "$out"
# A blank line inside the require block must not become a DEP with an empty name.
absent  "blank line is not a dep"         "DEP	go.mod		"                   "$out"
rm -rf "$r"

# --- package.json + .nvmrc ------------------------------------------------
r=$(newrepo)
printf '{"dependencies":{"next":"15.0.1"},"devDependencies":{"typescript":"5.4.0"},"engines":{"node":">=22"}}\n' > "$r/package.json"
printf 'v22.11.0\n' > "$r/.nvmrc"
out=$(run "$r")
check "package.json dep"        "DEP	package.json	next	15.0.1"        "$out"
check "devDependency included"  "DEP	package.json	typescript	5.4.0"  "$out"
check "engines.node RUNTIME"    "RUNTIME	package.json	node	>=22"      "$out"
check ".nvmrc yields a RUNTIME" "RUNTIME	.nvmrc	node	22.11.0"          "$out"
rm -rf "$r"

# --- Tier B: version-bearing refs, with polarity context ------------------
r=$(newrepo)
mkdir -p "$r/docs"
printf 'Use NODEJS_22_X. NODEJS_20_X reached Lambda EOL 2026-04-30.\n' > "$r/docs/deploy.md"
out=$(run "$r")
check "ref detected"                   "REF	docs/deploy.md:1"            "$out"
check "surrounding line is carried"    "reached Lambda EOL"               "$out"
rm -rf "$r"

# --- empty repo: N/A must be a counted claim, not a bare assertion --------
r=$(newrepo)
printf 'nothing here\n' > "$r/README.md"
out=$(run "$r")
check  "SUMMARY always prints"      "SUMMARY	files="        "$out"
check  "zero manifests reported"    "manifests=0"           "$out"
absent "no phantom DEP records"     "DEP	"                  "$out"
rm -rf "$r"

# --- scanner honesty: absence is never reported as clean ------------------
r=$(newrepo)
printf 'x\n' > "$r/README.md"
out=$(PATH=/usr/bin:/bin run "$r")
if grep -q '^SCAN' <<<"$out"; then ok "a SCAN record is always emitted"; else bad "a SCAN record is always emitted"; fi
absent "never claims clean when unscannable" "no vulnerabilities found" "$out"
rm -rf "$r"

# --- exit code: findings are data, not failure ----------------------------
r=$(newrepo)
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
( cd "$r" && bash "$SCRIPT" >/dev/null 2>&1 )
if [[ $? -eq 0 ]]; then ok "exit 0 on a normal run"; else bad "exit 0 on a normal run"; fi
rm -rf "$r"

# --- not a git repo: must not explode -------------------------------------
d=$(mktemp -d); printf 'x\n' > "$d/README.md"
( cd "$d" && bash "$SCRIPT" >/dev/null 2>&1 )
if [[ $? -eq 0 ]]; then ok "exit 0 outside a git repo"; else bad "exit 0 outside a git repo"; fi
rm -rf "$d"

# --- THE REGRESSION: a gitignored lockfile is still scanned ----------------
# regist, exactly. `.gitignore` wholesale-ignores the Xcode bundle, osv-scanner
# respects .gitignore, and the SwiftPM graph went unexamined while the report read
# as complete. Pass 1 here scans only go.mod, so Package.resolved must reach pass 2.
r=$(newrepo); mkstub "$r"
printf 'ios/*.xcodeproj\n' > "$r/.gitignore"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
mkdir -p "$r/ios/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
P="$r/ios/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
printf '{"originHash":"x","version":3,"pins":[{"identity":"swift-nio","kind":"remoteSourceControl","location":"https://github.com/apple/swift-nio.git","state":{"revision":"abc","version":"2.95.0"}}]}\n' > "$P"
out=$(runstub "$r" "go.mod")
check "gitignored lockfile is discovered"  "Package.resolved	swift	lock	scannable	gitignored" "$out"
check "gitignored lockfile reaches pass 2" "SCANNED	ios/App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$out"
check "swift counted as scanned"           "COVERAGE	swift	covered"     "$out"
check "swift pins yield DEP records"       "swift-nio	2.95.0"             "$out"
check "no coverage gaps here"              "coverage_gaps=0"                "$out"
rm -rf "$r"

# --- Package.resolved schema generations ----------------------------------
# v1 nests pins under `object`; v2 and v3 put them at the top level. All three are
# live under ~/dev, so parsing only one shape silently drops a whole repo's graph.
r=$(newrepo); mkstub "$r"
printf '{"object":{"pins":[{"package":"Alamofire","state":{"version":"5.9.0"}}]},"version":1}\n' > "$r/Package.resolved"
out=$(runstub "$r" "Package.resolved")
check "v1 object.pins parsed" "Alamofire	5.9.0" "$out"
rm -rf "$r"

# --- an unscanned ecosystem is a GAP with a stated cause -------------------
# The invariant: no output shape may imply complete when it was not. Pass 1 scans
# the go.mod and nothing else; cocoapods has no extractor, so it can never be
# covered and must say so rather than going quiet.
r=$(newrepo); mkstub "$r"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
printf 'PODS:\n  - Alamofire (5.0.0)\n' > "$r/Podfile.lock"
out=$(runstub "$r" "go.mod")
check  "covered ecosystem says covered"   "COVERAGE	go	covered"          "$out"
check  "uncovered ecosystem is a GAP"     "COVERAGE	cocoapods	GAP"      "$out"
check  "the GAP states a cause"           "no scanner extractor supports"   "$out"
check  "SUMMARY counts the gap"           "coverage_gaps=1"                 "$out"
check  "SUMMARY separates the two counts" "ecosystems=2 scanned_ecosystems=1" "$out"
absent "Podfile.lock never reaches -L"    "Podfile.lock	cocoapods	lock	scannable" "$out"
rm -rf "$r"

# --- pass 2 closes a gap pass 1 left, and that is observable --------------
# Pass 1 reads only go.mod. package-lock.json is scannable and unscanned, so the
# discovered-minus-scanned diff must hand it to pass 2 and node must end covered.
# This is the diff logic itself, independent of the gitignore case above.
r=$(newrepo); mkstub "$r"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
printf '{"name":"t","lockfileVersion":3,"packages":{}}\n' > "$r/package-lock.json"
out=$(runstub "$r" "go.mod")
check "pass 2 picks up what pass 1 skipped" "SCANNED	package-lock.json" "$out"
check "and the ecosystem ends covered"      "ecosystems=2 scanned_ecosystems=2" "$out"
rm -rf "$r"

# --- a manifest with no lockfile is a GAP, and says why -------------------
# The third GAP cause. A Gemfile declares dependencies but pins nothing, so there
# is nothing for a scanner to check, and "ruby: covered" would be a lie.
r=$(newrepo); mkstub "$r"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
printf "source 'https://rubygems.org'\ngem 'rails'\n" > "$r/Gemfile"
out=$(runstub "$r" "go.mod")
check "manifest-only ecosystem is a GAP" "COVERAGE	ruby	GAP"       "$out"
check "and names the missing lockfile"   "no lockfile found for this ecosystem" "$out"
rm -rf "$r"

# --- coverage never counts .git bookkeeping -------------------------------
# osv-scanner walks .git and reports git-lfs lock files as scanned sources. The
# previous SCAN filter kept exactly those (they say "found 0 packages") and
# dropped every real coverage line.
r=$(newrepo); mkstub "$r"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
mkdir -p "$r/.git/lfs/cache/locks/refs/heads/deps"
printf 'x\n' > "$r/.git/lfs/cache/locks/refs/heads/deps/web"
out=$(runstub "$r" "go.mod .git/lfs/cache/locks/refs/heads/deps/web")
absent "no SCANNED record under .git" "SCANNED	.git/" "$out"
check  "the real source still counts" "SCANNED	go.mod"  "$out"
rm -rf "$r"

# --- a path with a space survives the -L list -----------------------------
r=$(newrepo); mkstub "$r"
mkdir -p "$r/my app"
printf '{"name":"t","lockfileVersion":3,"packages":{}}\n' > "$r/my app/package-lock.json"
out=$(runstub "$r" "")
check "space in path reaches pass 2" "SCANNED	my app/package-lock.json" "$out"
rm -rf "$r"

# --- FIX grouping: many advisories, one upgrade ---------------------------
# The key is (package, source, installed version) with the highest fixed version.
# brace-expansion is the trap: same package, same source, two installed versions
# and two different fixed versions, so a package-only key prints a wrong target.
r=$(newrepo); mkstub "$r"
printf '{"name":"t","lockfileVersion":3,"packages":{}}\n' > "$r/package-lock.json"
cat > "$r/table.txt" <<'TBL'
+-------------------------------------+------+-----------+-----------------+---------+---------------+-------------------+
| OSV URL                             | CVSS | ECOSYSTEM | PACKAGE         | VERSION | FIXED VERSION | SOURCE            |
+-------------------------------------+------+-----------+-----------------+---------+---------------+-------------------+
| https://osv.dev/GHSA-aaaa-1111-bbbb | 8.3  | npm       | next            | 16.2.10 | 16.2.11       | package-lock.json |
| https://osv.dev/GHSA-cccc-2222-dddd | 6.3  | npm       | next            | 16.2.10 | 16.2.11       | package-lock.json |
| https://osv.dev/GHSA-eeee-3333-ffff | 7.7  | npm       | brace-expansion | 5.0.6   | 5.0.7         | package-lock.json |
| https://osv.dev/GHSA-gggg-4444-hhhh | 7.5  | npm       | brace-expansion | 5.0.6   | 5.0.8         | package-lock.json |
| https://osv.dev/GHSA-iiii-5555-jjjj | 7.5  | npm       | brace-expansion | 1.1.16  | 5.0.8         | package-lock.json |
+-------------------------------------+------+-----------+-----------------+---------+---------------+-------------------+
Total 2 packages affected by 5 known vulnerabilities (0 Critical, 4 High, 1 Medium, 0 Low, 0 Unknown) from 1 ecosystem.
TBL
out=$(runstub "$r" "package-lock.json" "$r/table.txt")
check "advisories collapse to one upgrade"  "FIX	package-lock.json	next	16.2.10	16.2.11	2	8.3" "$out"
check "highest fixed version wins"          "FIX	package-lock.json	brace-expansion	5.0.6	5.0.8	2	7.7" "$out"
check "installed versions stay separate"    "FIX	package-lock.json	brace-expansion	1.1.16	5.0.8	1	7.5" "$out"
absent "table borders are not findings"     "SCAN	osv-scanner	+---"     "$out"
rm -rf "$r"

# --- a walk is not a query: coverage needs a verdict ----------------------
# osv-scanner walks the filesystem first and queries the vulnerability database
# once, afterwards. With the network down it still prints a `Scanned <path>` line
# for every file, then dies with no verdict. Crediting coverage off those lines
# reproduces this pass's original bug one level deeper: an ecosystem reported
# covered when nothing checked it. Only `Total N` or `No issues found` counts.
r=$(newrepo)
mkdir -p "$r/.stub"
cat > "$r/.stub/osv-scanner" <<'STUB'
#!/usr/bin/env bash
echo "Scanned $PWD/package-lock.json file and found 42 packages"
echo "End status: 1 dirs visited"
echo 'error when retrieving vulns: max retries exceeded: attempt 4: request failed: Post "https://api.osv.dev/v1/querybatch"'
exit 127
STUB
chmod +x "$r/.stub/osv-scanner"
printf '{"name":"t","lockfileVersion":3,"packages":{}}\n' > "$r/package-lock.json"
out=$( cd "$r" && PATH="$r/.stub:$PATH" bash "$SCRIPT" 2>&1 )
absent "a failed query is never coverage"  "SCANNED	package-lock.json" "$out"
absent "and never reports covered"         "COVERAGE	node	covered"    "$out"
check  "it reports a GAP instead"          "COVERAGE	node	GAP"        "$out"
check  "naming the failed query"           "vulnerability query returned no verdict" "$out"
check  "and says so in NOTE"               "NOTE	scan-incomplete"        "$out"
check  "SUMMARY reflects zero coverage"    "scanned_ecosystems=0 coverage_gaps=1"    "$out"
rm -rf "$r"

# --- zero packages extracted is zero packages checked ---------------------
# osv-scanner reads a v1-schema Package.resolved as `found 0 packages` while the
# identical pin in v3 schema yields three advisories up to CVSS 8.7. A file the
# extractor did not understand must not count as coverage, and the cause reported
# must be the extractor, not a failed query.
# The verdict IS present here, and one file extracts fine while the other yields
# zero. That isolates the zero-package rule from the verdict gate: if the two were
# tested together, disabling the count check would still pass because the verdict
# gate alone would have stopped the run.
r=$(newrepo)
mkdir -p "$r/.stub"
cat > "$r/.stub/osv-scanner" <<'STUB'
#!/usr/bin/env bash
echo "Scanned $PWD/Package.resolved file and found 0 packages"
echo "Scanned $PWD/go.mod file and found 4 packages"
echo "No issues found"
exit 0
STUB
chmod +x "$r/.stub/osv-scanner"
printf '{"version":1,"object":{"pins":[{"package":"swift-nio","state":{"version":"2.95.0"}}]}}\n' > "$r/Package.resolved"
printf 'module x\n\ngo 1.26\n' > "$r/go.mod"
out=$( cd "$r" && PATH="$r/.stub:$PATH" bash "$SCRIPT" 2>&1 )
absent "0 packages is not a SCANNED record"   "SCANNED	Package.resolved" "$out"
check  "but a real extraction still counts"   "SCANNED	go.mod"           "$out"
check  "the unextracted ecosystem is a GAP"   "COVERAGE	swift	GAP"     "$out"
check  "blamed on the extractor, not a query" "no scanner extractor supports" "$out"
check  "the extracted one stays covered"      "COVERAGE	go	covered"     "$out"
check  "v1 pins still parse into DEP"         "swift-nio	2.95.0"          "$out"
rm -rf "$r"

# --- alias continuation rows are not advisories ---------------------------
# An advisory with aliases renders one data row plus a continuation row per alias,
# carrying the alias URL and empty cells. Counting them inflates the count past
# the tool's own Total and emits a FIX row with no package and no version.
r=$(newrepo); mkstub "$r"
printf '{"name":"t","lockfileVersion":3,"packages":{}}\n' > "$r/package-lock.json"
cat > "$r/table.txt" <<'TBL'
| https://osv.dev/GHSA-29mw-wpgm-hmr9 | 5.3  | npm       | lodash  | 4.17.11 | 4.17.21       | package-lock.json |
| https://osv.dev/GHSA-r5fr-rjxr-66jc |      |           |         |         |               | package-lock.json |
| https://osv.dev/GHSA-jf85-cpcp-j695 | 9.1  | npm       | lodash  | 4.17.11 | 4.17.12       | package-lock.json |
Total 1 package affected by 2 known vulnerabilities (1 Critical, 1 Medium, 0 Low, 0 Unknown) from 1 ecosystem.
TBL
out=$(runstub "$r" "package-lock.json" "$r/table.txt")
check  "alias rows do not inflate the count" "FIX	package-lock.json	lodash	4.17.11	4.17.21	2	9.1" "$out"
# The garbage row an alias produces keeps the SOURCE cell (it is the last column
# and stays populated) and empties package and version, so the shape to forbid is
# `FIX <source> <empty> <empty>`, not a run of leading tabs. Asserting the wrong
# shape here passed whether or not the alias filter existed.
absent "and produce no package-less FIX row" "FIX	package-lock.json			"  "$out"
check  "exactly one FIX row survives"        "FIX	package-lock.json	lodash" "$out"
if [[ $(grep -c '^FIX' <<<"$out") -eq 1 ]]; then ok "no second FIX row from the alias"
else bad "no second FIX row from the alias"; grep '^FIX' <<<"$out" | sed 's/^/         /'; fi
rm -rf "$r"

# --- the REF cap announces what it dropped --------------------------------
# A cap that stays quiet is a silent claim of completeness. regist trips this at
# 211 matches and sophie at 239, and both used to vanish without a word.
r=$(newrepo)
i=0; : > "$r/many.md"
while [[ $i -lt 260 ]]; do printf 'use NODEJS_22_X here\n' >> "$r/many.md"; i=$((i+1)); done
out=$(run "$r")
check "the cap reports its own truncation" "NOTE	ref-cap	showing 200 of 260" "$out"
check "and names the dropped count"        "60 dropped at the cap"             "$out"
rm -rf "$r"

# --- under the cap, no note --------------------------------------------------
r=$(newrepo)
printf 'use NODEJS_22_X here\n' > "$r/few.md"
out=$(run "$r")
absent "no cap note when nothing is dropped" "NOTE	ref-cap" "$out"
rm -rf "$r"

echo
echo "freshness.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
