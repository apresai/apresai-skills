#!/usr/bin/env bash
# pipeline.test.sh: suite for pipeline.sh.
#
# Locks the 3.0.0 contract: two depths (fast, deep) that change how many
# agents look, never which findings are kept. Every non-empty diff runs gate,
# scans, tests, freshness-audit, skim, impl-review, verify, and receipt. Deep
# adds challenger and sweep. Dependency updates are never a review node.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/pipeline.sh"
pass=0; fail=0
TMPS=()
cleanup(){ local d; for d in "${TMPS[@]+"${TMPS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}
absent(){
  if grep -qF -- "$2" <<<"$3"; then
    bad "$1"; printf '       must NOT contain: %s\n' "$2"
  else ok "$1"; fi
}
line_is(){ # exact KEY=value line
  if grep -qxF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted line: %s\n       got: %s\n' "$2" "$(grep "^${2%%=*}=" <<<"$3" || true)"
  fi
}

newrepo(){ local d; d=$(mktemp -d); TMPS+=("$d"); ( cd "$d" && git init -q . ); echo "$d"; }
run(){ ( cd "$1" && shift && bash "$SCRIPT" "$@" 2>&1 ); }
nodes_of(){ printf '%s\n' "$1" | grep '^NODES=' || true; }
skip_of(){ printf '%s\n' "$1" | grep '^SKIP=' || true; }
has_node(){ check "$1" ",$2," ",$(nodes_of "$3" | sed 's/^NODES=//'),"; }
no_node(){ absent "$1" ",$2," ",$(nodes_of "$3" | sed 's/^NODES=//'),"; }

core(){ # nodes every non-empty diff runs, at either depth
  local label="$1" out="$2" node
  for node in gate docs-drift contract-mirror tests freshness-audit docs-apply skim impl-review verify receipt; do
    has_node "$label: runs $node" "$node" "$out"
  done
  no_node "$label: no freshness-update in review" "freshness-update" "$out"
  no_node "$label: no score node" "score" "$out"
  absent "$label: no TIER key" "TIER=" "$out"
}
fast(){ core "$1" "$2"; line_is "$1: MODE=fast" "MODE=fast" "$2"
  no_node "$1: fast has no challenger" "challenger" "$2"; no_node "$1: fast has no sweep" "sweep" "$2"; }
deep(){ core "$1" "$2"; line_is "$1: MODE=deep" "MODE=deep" "$2"
  has_node "$1: deep runs challenger" "challenger" "$2"; has_node "$1: deep runs sweep" "sweep" "$2"; }

# --- 1. docs typo is fast, one finder, no simplify ----------------------------
r=$(newrepo)
printf 'A readme.\n\nJust three plain lines.\n' > "$r/README.md"
out=$(run "$r")
fast "docs typo" "$out"
line_is "docs typo has exactly 1 agent" "AGENTS=1" "$out"
no_node "docs typo does not simplify" "simplify" "$out"
check "docs typo skips simplify" "simplify" "$(skip_of "$out")"
rm -rf "$r"

# --- 2. tiny Go file is fast and simplifies -----------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
fast "tiny go" "$out"
has_node "tiny go simplifies" "simplify" "$out"
rm -rf "$r"

# --- 3. manifest only is fast; review never updates deps ----------------------
r=$(newrepo)
printf 'module example.com/x\n\ngo 1.22\n' > "$r/go.mod"
out=$(run "$r")
fast "manifest only" "$out"
rm -rf "$r"

# --- 4. CLAUDE.md alone is deep, never simplified -----------------------------
r=$(newrepo)
printf '# Project\n\nAlways run tests.\n' > "$r/CLAUDE.md"
out=$(run "$r")
deep "exec-md" "$out"
no_node "exec-md does not simplify" "simplify" "$out"
check "exec-md reason" "executable prompt content" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 5. AGENTS.md, Claude.md, SKILL.md are prompt content ---------------------
for f in AGENTS.md Claude.md SKILL.md; do
  r=$(newrepo); printf '# x\n' > "$r/$f"; out=$(run "$r")
  line_is "$f is deep" "MODE=deep" "$out"; rm -rf "$r"
done

# --- 6. mixed prompt plus code: deep, simplify still runs for the code --------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
printf '# Skill\n' > "$r/SKILL.md"
out=$(run "$r")
deep "mixed" "$out"
has_node "mixed simplifies the code" "simplify" "$out"
rm -rf "$r"

# --- 7. code plus prose: deep counts the prose block as its own finder --------
r=$(newrepo)
for i in $(seq 1 16); do printf 'package p\n\nfunc F%s() {}\n' "$i" > "$r/f$i.go"; done
printf 'readme\n' > "$r/README.md"
out=$(run "$r")
deep "17 files" "$out"
check "17 files reason names the count" "17 files" "$(grep '^REASON=' <<<"$out")"
line_is "go plus prose block counted" "PROSE_BLOCKS=1" "$out"
line_is "deep agents = go + prose + challenger + sweep" "AGENTS=4" "$out"
rm -rf "$r"

# --- 8. over 400 production lines is deep -------------------------------------
r=$(newrepo)
{ printf 'package p\n\nfunc F() {\n'; n=0; while [[ $n -lt 420 ]]; do echo "	_ = $n"; n=$((n+1)); done; printf '}\n'; } > "$r/big.go"
out=$(run "$r")
deep "420 lines" "$out"
check "line reason" "production lines" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 9. a large test-only file stays fast; tests are not production lines -----
r=$(newrepo)
{ printf 'package p\n\nfunc TestX(t *testing.T) {\n'; n=0; while [[ $n -lt 500 ]]; do echo "	_ = $n"; n=$((n+1)); done; printf '}\n'; } > "$r/x_test.go"
out=$(run "$r")
fast "test-only" "$out"
line_is "test-only has zero production lines" "LINES=0" "$out"
no_node "test-only does not simplify" "simplify" "$out"
rm -rf "$r"

# --- 10. high-risk paths are deep; look-alikes are not ------------------------
for f in auth.go internal/oauth/x.go billing/pay.go migrations/001.sql; do
  r=$(newrepo); mkdir -p "$r/$(dirname "$f")"; printf 'x\n' > "$r/$f"; out=$(run "$r")
  line_is "$f is deep" "MODE=deep" "$out"; rm -rf "$r"
done
r=$(newrepo); printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 0.0.1\n' > "$r/openapi.yaml"; out=$(run "$r")
deep "openapi" "$out"; check "openapi risk" "api" "$(grep '^RISK=' <<<"$out")"; rm -rf "$r"
for f in author.go handler.go; do
  r=$(newrepo); printf 'package p\n\nfunc X() {}\n' > "$r/$f"; out=$(run "$r")
  line_is "$f is not a risk path" "RISK=none" "$out"; line_is "$f is fast" "MODE=fast" "$out"; rm -rf "$r"
done

# --- 11. shell, terraform, and dart count as code -----------------------------
for f in deploy.sh main.tf lib/app.dart; do
  r=$(newrepo); mkdir -p "$r/$(dirname "$f")"; printf 'x = 1\n' > "$r/$f"; out=$(run "$r")
  has_node "$f simplifies" "simplify" "$out"; rm -rf "$r"
done

# --- 12. --full forces deep ---------------------------------------------------
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r" --full)
deep "--full readme" "$out"
check "--full reason" "--full" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 13. failed routing is deep and never simplifies --------------------------
d=$(mktemp -d); TMPS+=("$d")
cp "$SCRIPT" "$d/pipeline.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$d/chad-review-route.sh"
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
printf '# Project\n' > "$r/CLAUDE.md"
out=$( cd "$r" && bash "$d/pipeline.sh" 2>&1 )
deep "route failed" "$out"
no_node "route failed does not simplify" "simplify" "$out"
check "route failed reason" "routing failed" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 14. SCOPE_ASK past 50 files ----------------------------------------------
r=$(newrepo)
for i in $(seq 1 51); do printf 'x\n' > "$r/d$i.md"; done
out=$(run "$r")
line_is "51 files asks scope" "SCOPE_ASK=1" "$out"
check "scope reason" "size ask line" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 15. a changed plan runs spec-vs-diff before simplify and docs-apply ------
r=$(newrepo)
printf '# Plan\n\nDo the thing.\n' > "$r/PLAN.md"
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
line_is "plan arms SPEC" "SPEC=yes" "$out"
case "$(nodes_of "$out")" in
  *freshness-audit,spec-vs-diff,simplify,docs-apply*) ok "spec-vs-diff precedes every apply node" ;;
  *) bad "spec-vs-diff precedes every apply node"; printf '       got: %s\n' "$(nodes_of "$out")" ;;
esac
line_is "spec adds an agent" "AGENTS=2" "$out"
rm -rf "$r"

# --- 16. a committed, untouched PLAN.md does not arm spec ---------------------
r=$(newrepo)
printf '# Old plan\n' > "$r/PLAN.md"
( cd "$r" && git add -A && git commit -qm plan ) >/dev/null
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
out=$(run "$r")
line_is "untouched PLAN.md is SPEC=no" "SPEC=no" "$out"
no_node "untouched PLAN.md has no spec node" "spec-vs-diff" "$out"
rm -rf "$r"

# --- 17. node order -----------------------------------------------------------
r=$(newrepo)
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
n=$(nodes_of "$(run "$r")")
case "$n" in
  NODES=untracked-backup,gate,*impl-review,challenger,verify,sweep,receipt) ok "backup and gate first, verify after finders, receipt last" ;;
  *) bad "backup and gate first, verify after finders, receipt last"; printf '       got: %s\n' "$n" ;;
esac
rm -rf "$r"

# --- 18. tracked-only change skips the backup ---------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
( cd "$r" && git add -A && git commit -qm base ) >/dev/null
printf 'package p\n\nfunc F() { _ = 1 }\n' > "$r/f.go"
out=$(run "$r")
no_node "tracked-only has no backup" "untracked-backup" "$out"
check "tracked-only skips backup" "untracked-backup" "$(skip_of "$out")"
rm -rf "$r"

# --- 19. last-commit mode ------------------------------------------------------
r=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$r/f.go"
( cd "$r" && git add -A && git commit -qm one ) >/dev/null
out=$(run "$r" --last-commit)
fast "last-commit" "$out"
rm -rf "$r"

# --- 20. empty repo, non-repo, bad flag ---------------------------------------
r=$(newrepo)
out=$(run "$r")
line_is "empty tree is none" "MODE=none" "$out"
line_is "empty tree has no nodes" "NODES=" "$out"
check "empty SKIP lists verify" "verify" "$(skip_of "$out")"
check "empty SKIP lists sweep" "sweep" "$(skip_of "$out")"
rm -rf "$r"
d=$(mktemp -d /private/tmp/pipeline-nonrepo.XXXXXX 2>/dev/null || mktemp -d); TMPS+=("$d")
if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
  ok "non-repo case skipped: temp dir is inside a git work tree"
else
  out=$( cd "$d" && bash "$SCRIPT" 2>&1 )
  line_is "non-repo is none" "MODE=none" "$out"
  check "non-repo reason" "REASON=not a git repository" "$out"
fi
r=$(newrepo)
( cd "$r" && bash "$SCRIPT" --bogus >/dev/null 2>&1 ); rc=$?
if [[ "$rc" -eq 2 ]]; then ok "unknown flag exits 2"; else bad "unknown flag exits 2 (got $rc)"; fi
rm -rf "$r"

# --- 21. required keys; every listed node has a node file ---------------------
r=$(newrepo)
printf 'package auth\n\nfunc Login() {}\n' > "$r/auth.go"
printf '# Plan\n' > "$r/PLAN.md"
out=$(run "$r")
for k in MODE RISK AGENTS SPEC SCOPE_ASK UNTRACKED FILES LINES LANG_BLOCKS PROSE_BLOCKS NODES SKIP REASON; do
  check "key $k prints" "$k=" "$out"
done
for node in $(nodes_of "$out" | sed 's/^NODES=//' | tr ',' ' '); do
  if [[ -f "$HERE/nodes/$node.md" ]]; then ok "node file exists: $node"; else bad "node file exists: $node"; fi
done
rm -rf "$r"

echo "pipeline.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
