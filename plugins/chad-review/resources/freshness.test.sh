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

echo
echo "freshness.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
