#!/usr/bin/env bash
# pipeline.test.sh: suite for pipeline.sh.
#
# Locks the 3.0.0 contract: two depths (fast, deep) that change how many
# agents look, never which findings are kept. Also locks the node order the
# shared design fixes (real-tree gate, tests and apply before the scans) and
# --staged, which keeps a pr-stage.sh worktree's branch files out of the
# untracked-backup decision. Every non-empty diff runs gate,
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
  # NODES is pulled out once, then every membership test is pure bash.
  local label="$1" out="$2" node line list=",,"
  while IFS= read -r line; do
    case "$line" in NODES=*) list=",${line#NODES=},"; break ;; esac
  done <<<"$out"
  for node in gate docs-drift contract-mirror tests freshness-audit docs-apply skim impl-review verify receipt; do
    if [[ "$list" == *",$node,"* ]]; then ok "$label: runs $node"; else
      bad "$label: runs $node"; printf '       wanted: ,%s,\n       got: %s\n' "$node" "$list"; fi
  done
  if [[ "$list" == *",freshness-update,"* ]]; then bad "$label: no freshness-update in review"
  else ok "$label: no freshness-update in review"; fi
  if [[ "$list" == *",score,"* ]]; then bad "$label: no score node"; else ok "$label: no score node"; fi
  if [[ "$out" == *"TIER="* ]]; then bad "$label: no TIER key"; printf '       must NOT contain: TIER=\n'
  else ok "$label: no TIER key"; fi
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
# Scans read the post-apply (staged) content, so they follow the apply nodes.
case "$(nodes_of "$out")" in
  NODES=untracked-backup,gate,tests,freshness-audit,spec-vs-diff,simplify,docs-apply,docs-drift,contract-mirror,skim,impl-review,*) ok "real-tree nodes, then apply, then scans" ;;
  *) bad "real-tree nodes, then apply, then scans"; printf '       got: %s\n' "$(nodes_of "$out")" ;;
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
# --- 22. exact SKIP=none when every node runs (same repo and run as 21) -------
line_is "every node listed gives SKIP=none" "SKIP=none" "$out"
rm -rf "$r"

# --- 23. Swift codegen hint is not an OpenAPI spec ----------------------------
r=$(newrepo)
mkdir -p "$r/App"
printf 'import Foundation\n\nlet x = 1\n' > "$r/App/Main.swift"
out=$(run "$r")
line_is "swift-only is RISK=none" "RISK=none" "$out"
line_is "swift-only is fast" "MODE=fast" "$out"
rm -rf "$r"

# --- 24. an OpenAPI spec found by content, not path, is still RISK=api --------
r=$(newrepo)
mkdir -p "$r/api"
printf 'openapi: 3.0.0\ninfo:\n  title: t\n  version: 0.0.1\n' > "$r/api/spec.yaml"
out=$(run "$r")
check "content-detected spec is RISK=api" "api" "$(grep '^RISK=' <<<"$out")"
line_is "content-detected spec is deep" "MODE=deep" "$out"
rm -rf "$r"

# --- 25. status-bearing docs force deep ---------------------------------------
r=$(newrepo)
mkdir -p "$r/docs"
printf '# Feature\n\n**Status:** Active\n\n## History\n\nRetired 2025.\n' > "$r/docs/feature.md"
out=$(run "$r")
deep "status-bearing" "$out"
check "status-bearing reason" "status-bearing docs" "$(grep '^REASON=' <<<"$out")"
line_is "status-bearing block is a finder" "AGENTS=3" "$out"
rm -rf "$r"
r=$(newrepo)
printf 'A readme.\n' > "$r/README.md"
out=$(run "$r")
check "fast reason names status docs" "no status-bearing docs" "$(grep '^REASON=' <<<"$out")"
rm -rf "$r"

# --- 26. --staged: branch-added files are the diff, not untracked work --------
staged=$(newrepo); real=$(newrepo)
printf 'package p\n\nfunc F() {}\n' > "$staged/f.go"
( cd "$staged" && git add -A && git commit -qm base && git -C "$real" commit -q --allow-empty -m base ) >/dev/null
{ printf 'package p\n\nfunc G() {\n'; n=0; while [[ $n -lt 420 ]]; do echo "	_ = $n"; n=$((n+1)); done; printf '}\n'; } > "$staged/new.go"
out=$(run "$staged")
line_is "unstaged run counts the branch file as untracked" "UNTRACKED=1" "$out"
has_node "unstaged run lists untracked-backup" "untracked-backup" "$out"
out=$(run "$staged" --staged "$real")
line_is "--staged takes UNTRACKED from the real tree" "UNTRACKED=0" "$out"
no_node "--staged with a clean real tree has no backup" "untracked-backup" "$out"
check "--staged skips the backup" "untracked-backup" "$(skip_of "$out")"
check "--staged still counts branch-added lines" "deep" "$(grep '^MODE=' <<<"$out")"
check "--staged reason names production lines" "production lines" "$(grep '^REASON=' <<<"$out")"
line_is "--staged keeps the branch files" "FILES=1" "$out"
printf 'wip\n' > "$real/notes.txt"
out=$(run "$staged" --staged "$real")
line_is "--staged counts real untracked work" "UNTRACKED=1" "$out"
has_node "--staged backs up the real tree's untracked work" "untracked-backup" "$out"
for args in "--staged" "--staged $real --last-commit" "--staged $staged"; do
  # shellcheck disable=SC2086
  ( cd "$staged" && bash "$SCRIPT" $args >/dev/null 2>&1 ); rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "usage exit 2: $args"; else bad "usage exit 2: $args (got $rc)"; fi
done
nr=$(mktemp -d /private/tmp/pipeline-nonrepo.XXXXXX 2>/dev/null || mktemp -d); TMPS+=("$nr")
if git -C "$nr" rev-parse --git-dir >/dev/null 2>&1; then
  ok "--staged non-repo case skipped: temp dir is inside a git work tree"
else
  ( cd "$staged" && bash "$SCRIPT" --staged "$nr" >/dev/null 2>&1 ); rc=$?
  if [[ "$rc" -eq 2 ]]; then ok "--staged on a non-repo exits 2"; else bad "--staged on a non-repo exits 2 (got $rc)"; fi
fi
rm -rf "$staged" "$real"

echo "pipeline.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
