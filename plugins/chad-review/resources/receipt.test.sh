#!/usr/bin/env bash
# receipt.test.sh: suite for receipt.sh.
#
# WHY THIS EXISTS
# The merge gate used to be session memory: "confirm a chad-review ran this
# session". A hand-rolled reviewer once satisfied that gate and merged 59 CVEs.
# The receipt binds a verdict to content (head sha + patch-id fingerprint),
# and this suite locks the properties the gate stands on: the exact reviewed
# head passes; a clean rebase with an unchanged diff converges; ANY substantive
# change, a NO-GO, a missing receipt, or a generic look-alike review fails
# closed; a receipt emitted on a dirty tree still matches after the exact
# same content is committed (the untracked fold-in equivalence, verified here
# by running the real code, not on paper); and either tool's receipt
# (chad-review or ultra-audit) satisfies the gate, with the newest ruling for
# the current content winning across both and a mismatched schema/tool pair
# never counting.
#
# Hermetic: every fixture repo, its bare "origin", the receipt store (via
# HOME/TMPDIR redirection is NOT enough since the store lives in .git), the gh
# stub, and the date stub all live inside one scratch WORKDIR that is removed
# on exit. gh is a PATH stub reading/writing $GH_STUB_DIR/{pr.json,
# comments.json}; GH_STUB_FAIL=1 simulates gh being broken or absent.
#
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/receipt.sh"
pass=0; fail=0

WORKDIR=$(mktemp -d) || { echo "cannot create scratch dir" >&2; exit 99; }
trap 'rm -rf "$WORKDIR"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export HOME="$WORKDIR" XDG_CONFIG_HOME="$WORKDIR/xdg" TMPDIR="$WORKDIR/tmp"
mkdir -p "$XDG_CONFIG_HOME" "$TMPDIR"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ # check <desc> <expected-substring> <actual>
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else
    bad "$1"; printf '       wanted: %s\n       got:\n%s\n' "$2" "$(sed 's/^/         /' <<<"$3")"
  fi
}
expect_code(){ # expect_code <desc> <want> <got>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (want exit $2, got $3)"; fi
}

# --- stubs -------------------------------------------------------------------

STUB="$WORKDIR/stub"; mkdir -p "$STUB"
export GH_STUB_DIR="$WORKDIR/ghstub"; mkdir -p "$GH_STUB_DIR"

cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
[[ "${GH_STUB_FAIL:-0}" == "1" ]] && exit 1
cmd="${1:-}"; shift || true
case "$cmd" in
  pr)
    sub="${1:-}"; shift || true
    case "$sub" in
      view)
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        jqf=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --json) shift 2 ;;
            --jq) jqf="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [[ -n "$jqf" ]]; then jq -r "$jqf" "$GH_STUB_DIR/pr.json"
        else cat "$GH_STUB_DIR/pr.json"; fi
        ;;
      comment)
        shift  # PR number
        bf=""
        while [[ $# -gt 0 ]]; do
          case "$1" in --body-file) bf="$2"; shift 2 ;; *) shift ;; esac
        done
        jq --rawfile b "$bf" --arg a "${GH_STUB_AUTHOR:-OWNER}" \
          '. + [{id: (length + 1), body: $b, author_association: $a}]' \
          "$GH_STUB_DIR/comments.json" > "$GH_STUB_DIR/c.tmp" \
          && mv "$GH_STUB_DIR/c.tmp" "$GH_STUB_DIR/comments.json"
        ;;
      *) exit 1 ;;
    esac
    ;;
  api)
    method=GET; path=""; bodyfile=""; body=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --paginate) shift ;;
        -f|--raw-field) v="$2"; body="${v#body=}"; shift 2 ;;
        -F|--field) v="$2"; bodyfile="${v#body=@}"; shift 2 ;;
        repos/*) path="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [[ "$method" == "GET" ]]; then
      cat "$GH_STUB_DIR/comments.json"
    else
      id="${path##*/}"
      body_args=(--arg b "$body")
      [[ -z "$bodyfile" ]] || body_args=(--rawfile b "$bodyfile")
      jq "${body_args[@]}" --argjson id "$id" \
        'map(if .id == $id then .body = $b else . end)' \
        "$GH_STUB_DIR/comments.json" > "$GH_STUB_DIR/c.tmp" \
        && mv "$GH_STUB_DIR/c.tmp" "$GH_STUB_DIR/comments.json"
    fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"

# A monotonic clock: each call advances one second, so receipt ordering and
# store pruning are deterministic regardless of wall time.
export DATE_STUB_COUNTER="$WORKDIR/date.n"
cat > "$STUB/date" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$DATE_STUB_COUNTER" 2>/dev/null || echo 0)
n=$((n+1)); printf '%s\n' "$n" > "$DATE_STUB_COUNTER"
case "$*" in
  *"+%Y-%m-%dT%H:%M:%SZ"*) printf '2026-07-31T12:%02d:%02dZ\n' $((n/60)) $((n%60)) ;;
  *"+%Y%m%dT%H%M%SZ"*)     printf '20260731T12%02d%02dZ\n' $((n/60)) $((n%60)) ;;
  *) /bin/date "$@" ;;
esac
EOF
chmod +x "$STUB/date"

export PATH="$STUB:$PATH"
export GH_STUB_FAIL=1   # default OFF; cases that want gh flip it to 0

reset_gh() { printf '[]\n' > "$GH_STUB_DIR/comments.json"; printf '{"number":7,"headRefOid":"%s"}\n' "$1" > "$GH_STUB_DIR/pr.json"; }

# newrepo: main with one pushed commit on a local bare origin, then a feature
# branch with one commit. Prints the repo path. Two traps this shape already
# hit: the bare origin must live OUTSIDE the working tree (inside it,
# `git add -A` silently commits origin.git/** and every later push dirties
# those tracked copies), and the unique name must come from mktemp, not a
# counter (newrepo runs inside $(), a subshell, so a counter increment never
# persists and every case would share one repo and one receipt store).
newrepo() {
  local d
  d=$(mktemp -d "$WORKDIR/repo.XXXXXX")
  git init -q --bare "$d-origin.git"
  ( cd "$d" \
    && git init -q -b main . \
    && printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n' > base.txt \
    && git add -A && git commit -qm base \
    && git remote add origin "$d-origin.git" \
    && git push -q origin main \
    && git checkout -qb feat \
    && printf 'feature\n' > feat.txt \
    && git add -A && git commit -qm feat ) >/dev/null 2>&1
  echo "$d"
}

emit(){ ( cd "$1" && shift && bash "$SCRIPT" emit "$@" 2>&1 ); }
verify(){ ( cd "$1" && shift && bash "$SCRIPT" verify "$@" 2>&1 ); echo "code=$?"; }
publish(){ ( cd "$1" && shift && bash "$SCRIPT" publish "$@" 2>&1 ); echo "code=$?"; }
store_of(){ echo "$1/.git/chad-review/receipts"; }
# jqedit <file> <jq args...>: edit a receipt in place; fail the case loudly
# (never write a stray "<empty>.tmp" into the cwd) if the receipt is missing.
jqedit(){ local f="$1"; shift
  if [[ -z "$f" || ! -f "$f" ]]; then bad "receipt file missing for jq edit"; return 1; fi
  jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }

# --- 1. emit on a clean tree, verify the exact head ---------------------------
r=$(newrepo)
out=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0)
check "emit prints an absolute receipt path" "$r/.git/chad-review/receipts/" "$out"
f=$(grep -o '/.*\.json' <<<"$out" | head -1)
if jq -e . "$f" >/dev/null 2>&1; then ok "the receipt is valid JSON"; else bad "the receipt is valid JSON"; fi
check "receipt records the verdict" '"verdict": "GO"' "$(cat "$f")"
pv=$(jq -r .version "$(dirname "$SCRIPT")/../.claude-plugin/plugin.json")
check "receipt records the plugin version" "\"plugin_version\": \"$pv\"" "$(cat "$f")"
check "receipt fingerprint is versioned" '"fingerprint": "patchid-v1:' "$(cat "$f")"
v=$(verify "$r")
check "exact head passes" "PASS: GO receipt" "$v"
check "pass names the mode" "(exact-head)" "$v"
check "verify exits 0" "code=0" "$v"

# --- 2. clean rebase with an unchanged diff converges -------------------------
( cd "$r" && git checkout -q main && printf 'unrelated\n' > other.txt \
  && git add -A && git commit -qm unrelated && git push -q origin main \
  && git checkout -q feat && git rebase -q main ) >/dev/null 2>&1
v=$(verify "$r")
check "clean rebase passes via the fingerprint" "PASS: GO receipt" "$v"
check "pass mode is convergence" "(convergence)" "$v"

# --- 3. a rebase that lands main changes inside the hunk context re-arms ------
r=$(newrepo)
( cd "$r" && sed -e 's/line8/line8 changed by feat/' base.txt > b.tmp && mv b.tmp base.txt \
  && git add -A && git commit -qm touch8 ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && git checkout -q main \
  && sed -e 's/line6/line6 changed by main/' base.txt > b.tmp && mv b.tmp base.txt \
  && git add -A && git commit -qm touch6 && git push -q origin main \
  && git checkout -q feat && git rebase -q main ) >/dev/null 2>&1
v=$(verify "$r")
check "near-hunk rebase fails closed" "FAIL: receipt(s) found but stale" "$v"
check "near-hunk rebase exits 1" "code=1" "$v"

# --- 4. any substantive change after the receipt is stale ----------------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && printf 'more\n' >> feat.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
v=$(verify "$r")
check "a changed diff is stale" "FAIL: receipt(s) found but stale" "$v"

# --- 5. a NO-GO receipt fails the gate ------------------------------------------
r=$(newrepo)
emit "$r" --verdict NO-GO >/dev/null
v=$(verify "$r")
check "NO-GO fails and is named" "verdict NO-GO" "$v"
check "NO-GO exits 1" "code=1" "$v"

# --- 6. a newer NO-GO shadows an older GO on the same content -------------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
emit "$r" --verdict NO-GO >/dev/null
v=$(verify "$r")
check "newest ruling for the content wins" "verdict NO-GO" "$v"

# --- 7. no receipt at all --------------------------------------------------------
r=$(newrepo)
v=$(verify "$r")
check "missing receipt fails" "FAIL: no valid review receipt" "$v"
check "missing receipt exits 1" "code=1" "$v"

# --- 8. a generic review comment never satisfies the gate ------------------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
jq -n '[{id: 1, author_association: "OWNER",
        body: "LGTM! Reviewed thoroughly.\n```json\n{\"reviewed\": true, \"verdict\": \"GO\"}\n```"}]' \
  > "$GH_STUB_DIR/comments.json"
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "a look-alike review comment never passes" "FAIL: no valid review receipt" "$v"

# --- 9. dirty-tree emit (untracked files), commit verbatim, verify ---------------
r=$(newrepo)
( cd "$r" && printf 'new file\n' > extra.txt && : > empty.txt \
  && printf '#!/bin/sh\ntrue\n' > tool.sh && chmod 755 tool.sh ) >/dev/null 2>&1
out=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0)
check "dirty emit records tree state" '"tree_state": "dirty"' "$(cat "$(grep -o '/.*\.json' <<<"$out" | head -1)")"
( cd "$r" && git add -A && git commit -qm addall ) >/dev/null 2>&1
v=$(verify "$r")
check "untracked fold-in survives the commit" "PASS: GO receipt" "$v"
check "fold-in match is convergence" "(convergence)" "$v"

# --- 9b. dirty-tree emit, tree UNCHANGED, bare verify passes ----------------------
# Regression (2026-08-12): verify defaulted to head-mode fingerprinting, so a
# receipt emitted from a dirty tree (untracked file present) was falsely
# reported stale by a bare verify seconds later, with nothing changed. verify
# now computes both modes and matches either.
r=$(newrepo)
( cd "$r" && printf 'wip note\n' > untracked.md ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r")
check "unchanged dirty tree verifies without --worktree" "PASS: GO receipt" "$v"
check "unchanged dirty tree match is convergence" "(convergence)" "$v"

# --- 10. dirty-tree emit (modified tracked file), commit verbatim ----------------
r=$(newrepo)
( cd "$r" && printf 'edited\n' >> base.txt ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && git add -A && git commit -qm edit ) >/dev/null 2>&1
v=$(verify "$r")
check "modified-tracked fold-in survives the commit" "PASS: GO receipt" "$v"

# --- 11. a dirty receipt's head_sha never counts as exact-head --------------------
r=$(newrepo)
( cd "$r" && printf 'edited\n' >> base.txt ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && git checkout -q -- base.txt ) >/dev/null 2>&1
v=$(verify "$r")
check "discarded dirty content is stale, not exact-head" "FAIL: receipt(s) found but stale" "$v"

# --- 12. binary content changes re-arm via --full-index ---------------------------
r=$(newrepo)
( cd "$r" && printf '\x00\x01\x02\x80\xff' > blob.bin && git add -A && git commit -qm bin ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && printf '\x00\x01\x03\x80\xff' > blob.bin && git add -A && git commit -qm bin2 ) >/dev/null 2>&1
v=$(verify "$r")
check "a binary byte flip is stale" "FAIL: receipt(s) found but stale" "$v"

# --- 13. publish is idempotent: one create, then update-in-place ------------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
GH_STUB_FAIL=0
p1=$(publish "$r" --pr 7)
first_body=$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")
p2=$(publish "$r" --pr 7)
GH_STUB_FAIL=1
check "first publish creates the comment" "published: new receipt comment" "$p1"
check "second publish updates in place" "published: updated receipt comment" "$p2"
n=$(jq 'length' "$GH_STUB_DIR/comments.json")
expect_code "exactly one receipt comment exists" "1" "$n"
check "the comment carries the marker" "chad-review-receipt v1" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"
expect_code "updating preserves the complete published receipt body" "$first_body" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"

# --- 14. verify reads the PR comment when the local store is gone -----------------
rm -f "$(store_of "$r")"/*.json
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "cross-machine verify passes from the PR comment" "PASS: GO receipt (github)" "$v"

# --- 15. a marker comment from an untrusted author is rejected --------------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
GH_STUB_FAIL=0 GH_STUB_AUTHOR=NONE publish "$r" --pr 7 >/dev/null
rm -f "$(store_of "$r")"/*.json
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "an untrusted author's receipt does not count" "FAIL: no valid review receipt" "$v"

# --- 16. gh unavailable degrades to local-only with a warning ---------------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r" --pr 7)   # GH_STUB_FAIL=1 is the ambient default
check "gh-less verify warns" "WARN: local-only verification" "$v"
check "gh-less verify still passes on the local receipt" "PASS: GO receipt (local)" "$v"

# --- 17. no origin remote: path identity, local flow works ------------------------
d="$WORKDIR/noorigin"; mkdir -p "$d"
( cd "$d" && git init -q -b main . && printf 'x\n' > f.txt && git add -A && git commit -qm base \
  && git checkout -qb feat && printf 'y\n' > g.txt && git add -A && git commit -qm feat ) >/dev/null 2>&1
out=$(emit "$d" --verdict GO --counts critical=0,high=0,medium=0,low=0 --base main)
check "no-origin emit works" "receipts/" "$out"
dphys=$(cd "$d" && pwd -P)
check "identity falls back to the path" "\"repo\": \"$dphys\"" "$(cat "$(grep -o '/.*\.json' <<<"$out" | head -1)")"
v=$(verify "$d" --base main)
check "no-origin verify passes" "PASS: GO receipt" "$v"

# --- 18. base resolution: origin/master picked; no base at all is exit 2 ----------
d="$WORKDIR/master"; mkdir -p "$d"
git init -q --bare "$WORKDIR/master-origin.git"
( cd "$d" && git init -q -b master . && printf 'x\n' > f.txt && git add -A && git commit -qm base \
  && git remote add origin "$WORKDIR/master-origin.git" && git push -q origin master \
  && git checkout -qb feat && printf 'y\n' > g.txt && git add -A && git commit -qm feat ) >/dev/null 2>&1
out=$(emit "$d" --verdict GO --counts critical=0,high=0,medium=0,low=0)
check "origin/master is found without a flag" '"base_ref": "origin/master"' "$(cat "$(grep -o '/.*\.json' <<<"$out" | head -1)")"
d="$WORKDIR/trunk"; mkdir -p "$d"
( cd "$d" && git init -q -b trunk . && printf 'x\n' > f.txt && git add -A && git commit -qm base \
  && git checkout -qb feat && printf 'y\n' > g.txt && git add -A && git commit -qm feat ) >/dev/null 2>&1
v=$( ( cd "$d" && bash "$SCRIPT" verify 2>&1 ); echo "code=$?" )
check "no resolvable base is a cannot-run" "CANNOT-RUN: no base ref" "$v"
check "cannot-run exits 2" "code=2" "$v"

# --- 19. two branches share the store without shadowing each other ----------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
( cd "$r" && git checkout -q main && git checkout -qb feat2 \
  && printf 'z\n' > z.txt && git add -A && git commit -qm feat2 ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v2=$(verify "$r")
( cd "$r" && git checkout -q feat ) >/dev/null 2>&1
v1=$(verify "$r")
check "second branch verifies on its own receipt" "PASS: GO receipt" "$v2"
check "first branch still verifies after the second emitted" "PASS: GO receipt" "$v1"

# --- 20. verify refuses a local HEAD that is not the PR head ----------------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
reset_gh "0000000000000000000000000000000000000000"
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "PR head mismatch fails" "is not the PR head" "$v"
check "PR head mismatch exits 1" "code=1" "$v"

# --- 21. the store prunes to the newest 20 ----------------------------------------
r=$(newrepo)
i=1; while [[ $i -le 25 ]]; do emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null; i=$((i+1)); done
n=$(ls -1 "$(store_of "$r")" | grep -c '\.json$')
expect_code "25 emits leave 20 receipts" "20" "$n"

# --- 22. a corrupt receipt fails closed, never crashes ----------------------------
r=$(newrepo)
mkdir -p "$(store_of "$r")"
printf '{"schema": "chad-review-receipt", "schema_version": 1, "tool": "chad-review", "verdict": "GO", "head_sha": "abc"}\n' \
  > "$(store_of "$r")/20260731T120000Z-corrupt.json"
printf 'not json at all\n' > "$(store_of "$r")/20260731T120001Z-junk.json"
v=$(verify "$r")
check "a receipt missing its fingerprint does not count" "FAIL: no valid review receipt" "$v"
check "corrupt candidates exit 1, not a crash" "code=1" "$v"

# --- 23. an ultra-audit receipt satisfies the same gate ---------------------------
r=$(newrepo)
out=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0)
check "ultra-audit emit writes its own store" "$r/.git/ultra-audit/receipts/" "$out"
if grep -qF "$r/.git/chad-review/receipts/" <<<"$out"; then
  bad "ultra-audit emit does not write the chad-review store"
else
  ok "ultra-audit emit does not write the chad-review store"
fi
f=$(grep -o '/.*\.json' <<<"$out" | head -1)
check "ultra-audit receipt names its tool" '"tool": "ultra-audit"' "$(cat "$f")"
check "ultra-audit receipt uses its schema" '"schema": "ultra-audit-receipt"' "$(cat "$f")"
v=$(verify "$r")
check "ultra-audit receipt passes verify" "PASS: GO receipt" "$v"
check "ultra-audit receipt verifies exact-head" "(exact-head)" "$v"
check "ultra-audit verify exits 0" "code=0" "$v"

# --- 24. newest ruling wins ACROSS tools on the same content ----------------------
r=$(newrepo)
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
emit "$r" --verdict NO-GO >/dev/null
v=$(verify "$r")
check "a newer chad-review NO-GO shadows an older ultra-audit GO" "verdict NO-GO" "$v"
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r")
check "a newer ultra-audit GO out-ranks the NO-GO again" "PASS: GO receipt" "$v"

# --- 25. ultra-audit publish and cross-machine verify via its own marker ----------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
out=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0)
f=$(grep -o '/.*\.json' <<<"$out" | head -1)
GH_STUB_FAIL=0
publish "$r" --pr 7 --file "$f" >/dev/null
GH_STUB_FAIL=1
check "the comment carries the ultra-audit marker" "ultra-audit-receipt v1" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"
rm -f "$r/.git/ultra-audit/receipts/"*.json "$r/.git/chad-review/receipts/"*.json 2>/dev/null
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "cross-machine verify passes from the ultra-audit comment" "PASS: GO receipt (github)" "$v"

# --- 26. a mismatched schema/tool pair is a forgery, not a receipt ----------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
f=$(ls -1 "$(store_of "$r")"/*.json | head -1)
jqedit "$f" '.schema = "ultra-audit-receipt"'
v=$(verify "$r")
check "ultra-audit schema with chad-review tool never counts" "FAIL: no valid review receipt" "$v"
jqedit "$f" '.schema = "chad-review-receipt" | .tool = "ultra-audit"'
v=$(verify "$r")
check "chad-review schema with ultra-audit tool never counts" "FAIL: no valid review receipt" "$v"

# --- 27. bare publish picks the newest receipt across both stores -----------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
GH_STUB_FAIL=0
p=$(publish "$r" --pr 7)
GH_STUB_FAIL=1
check "bare publish succeeds across stores" "published: new receipt comment" "$p"
check "bare publish picked the newer (ultra-audit) receipt" "ultra-audit-receipt v1" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
GH_STUB_FAIL=0
publish "$r" --pr 7 >/dev/null
GH_STUB_FAIL=1
check "reversed order picks the newer (chad-review) receipt" "chad-review-receipt v1" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"

# --- 28. an untrusted author's ultra-audit marker comment is rejected -------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
out=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0)
f=$(grep -o '/.*\.json' <<<"$out" | head -1)
GH_STUB_FAIL=0 GH_STUB_AUTHOR=NONE publish "$r" --pr 7 --file "$f" >/dev/null
rm -f "$r/.git/ultra-audit/receipts/"*.json "$r/.git/chad-review/receipts/"*.json 2>/dev/null
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "an untrusted author's ultra-audit receipt does not count" "FAIL: no valid review receipt" "$v"

# --- 29. an emitted_at tie is fail-closed: the non-GO ruling wins -----------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
out=$(emit "$r" --tool ultra-audit --verdict NO-GO)
f2=$(grep -o '/.*\.json' <<<"$out" | head -1)
ts=$(jq -r .emitted_at "$(ls -1 "$(store_of "$r")"/*.json | head -1)")
jqedit "$f2" --arg t "$ts" '.emitted_at = $t'
v=$(verify "$r")
check "tied timestamps let the NO-GO win" "verdict NO-GO" "$v"
check "tied-timestamp verify fails closed" "code=1" "$v"

# --- 30. a GO recording any open finding fails the gate mechanically -------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=1,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r")
check "GO with a critical count fails" "records 1 open finding" "$v"
check "contradicted GO exits 1" "code=1" "$v"
r=$(newrepo)
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=2,medium=3,low=0 >/dev/null
v=$(verify "$r")
check "ultra-audit GO with high and medium counts fails" "records 5 open finding" "$v"
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=5,low=2 >/dev/null
v=$(verify "$r")
check "GO with only medium/low counts fails" "records 7 open finding" "$v"
check "medium/low GO exits 1" "code=1" "$v"
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r")
check "GO with all-zero counts passes" "PASS: GO receipt" "$v"


# --- 31. 3.0.0 fail-closed paths ----------------------------------------------
r=$(newrepo)
out=$(emit "$r" --verdict GO); rc=$?
check "GO without --counts is refused" "requires --counts" "$out"
v=$(verify "$r")
check "refused GO left no receipt" "no valid review receipt" "$v"
r=$(newrepo)
f=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=00,low=0 | grep -o '/.*\.json' | head -1)
check "zero-padded count is written as 0" '"medium": 0,' "$(cat "$f")"
# A GO whose findings object is missing fails closed.
r=$(newrepo)
f=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
jqedit "$f" 'del(.findings)'
v=$(verify "$r")
check "GO with no findings object fails" "records 1 open finding" "$v"
# A GO missing medium/low fails closed.
jqedit "$f" '.findings = {critical: 0, high: 0}'
v=$(verify "$r")
check "GO missing medium/low fails" "records 2 open finding" "$v"
# A newer NO-GO with a non-numeric count still shadows the older GO.
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
sleep 1
f=$(emit "$r" --verdict NO-GO --counts critical=0,high=0,medium=1,low=0 | grep -o '/.*\.json' | head -1)
jqedit "$f" '.findings.medium = "1"'
v=$(verify "$r")
check "malformed newer NO-GO still shadows the GO" "verdict NO-GO" "$v"
# Same-second GOs: the one with counts wins the tie and fails.
r=$(newrepo)
f1=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
f2=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=1,low=0 | grep -o '/.*\.json' | head -1)
ts=$(jq -r .emitted_at "$f1")
jqedit "$f2" --arg t "$ts" '.emitted_at = $t'
v=$(verify "$r")
check "tied GO with counts fails closed" "records 1 open finding" "$v"
# --require-tool ultra-audit ignores chad-review receipts.
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r" --require-tool ultra-audit)
check "chad-review GO does not satisfy --require-tool ultra-audit" "no ultra-audit receipt found" "$v"
check "require-tool miss exits 1" "code=1" "$v"
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r" --require-tool ultra-audit)
check "ultra-audit GO satisfies --require-tool ultra-audit" "PASS: GO receipt" "$v"
r=$(newrepo)
emit "$r" --tool ultra-audit --verdict NO-GO --counts critical=0,high=1,medium=0,low=0 >/dev/null
sleep 1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r" --require-tool ultra-audit)
check "newer chad-review GO cannot override an ultra-audit NO-GO" "verdict NO-GO" "$v"
v=$(verify "$r" --require-tool bogus)
check "unknown --require-tool is usage" "code=2" "$v"

# --- 32. --counts parsing: all four keys with GO, 1 to 9 digits each ----------
r=$(newrepo)
out=$(emit "$r" --verdict GO --counts critical=0); rc=$?
check "partial --counts with GO is refused" "requires --counts naming critical, high, medium, and low" "$out"
expect_code "partial --counts with GO exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts ','); rc=$?
check "empty --counts ',' with GO is refused" "requires --counts naming" "$out"
expect_code "empty --counts with GO exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts critical=0,critical=0,high=0,medium=0); rc=$?
check "a duplicate key with one key missing is refused" "names critical twice" "$out"
expect_code "duplicate key exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts critical=-1,high=0,medium=0,low=0); rc=$?
check "a negative count is refused" "must be 1 to 9 digits" "$out"
expect_code "negative count exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts critical=18446744073709551616,high=0,medium=0,low=0); rc=$?
check "a 2^64 count is refused, never wrapped to 0" "must be 1 to 9 digits" "$out"
expect_code "overflowing count exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts critical=0000000000,high=0,medium=0,low=0); rc=$?
check "ten zero digits are refused" "must be 1 to 9 digits" "$out"
expect_code "ten-digit count exits 2" "2" "$rc"
out=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0,bogus=0); rc=$?
expect_code "an unknown --counts key exits 2" "2" "$rc"
v=$(verify "$r")
check "every refused emit left no receipt" "no valid review receipt" "$v"
f=$(emit "$r" --verdict GO --counts critical=000000000,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
check "nine zero digits are accepted as 0" '"critical": 0,' "$(cat "$f")"
r=$(newrepo)
f=$(emit "$r" --verdict NO-GO --counts critical=999999999,high=2 | grep -o '/.*\.json' | head -1)
check "a non-GO may carry partial counts; a nine-digit count is written verbatim" '"critical": 999999999, "high": 2, "medium": 0, "low": 0' "$(cat "$f")"
v=$(verify "$r")
check "the partial-count NO-GO fails the gate" "verdict NO-GO" "$v"

# --- 33. verify: negative and fractional counts are malformed, never summed ----
r=$(newrepo)
f=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
jqedit "$f" '.findings.critical = -3 | .findings.high = 3'
v=$(verify "$r")
check "critical -3 plus high 3 does not sum to zero" "records 4 open finding" "$v"
check "negative-count GO exits 1" "code=1" "$v"
jqedit "$f" '.findings = {critical: 0, high: 0, medium: 0.5, low: 0}'
v=$(verify "$r")
check "a fractional count counts as 1" "records 1 open finding" "$v"
jqedit "$f" '.findings = {critical: -9223372036854775808, high: 9223372036854775807, medium: 0, low: 0}'
v=$(verify "$r")
if grep -q '^PASS' <<<"$v"; then bad "a huge negative plus huge positive pair cannot pass"; else ok "a huge negative plus huge positive pair cannot pass"; fi

# --- 34. --require-tool ultra-audit refuses a GO from a plugin major below 3 --
r=$(newrepo)
f=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
check "a 3.x emit records a 3+ plugin_version" "\"plugin_version\": \"$pv\"" "$(cat "$f")"
jqedit "$f" '.plugin_version = "2.10.0"'
v=$(verify "$r" --require-tool ultra-audit)
check "a 2.10.0 ultra-audit GO fails the merge gate" "re-review with 3.0.0" "$v"
check "the 2.x refusal names the version" "chad-review 2.10.0" "$v"
check "the 2.x refusal exits 1" "code=1" "$v"
v=$(verify "$r")
check "a 2.10.0 GO still passes a plain verify" "PASS: GO receipt" "$v"
jqedit "$f" '.plugin_version = "unknown"'
v=$(verify "$r" --require-tool ultra-audit)
check "an unknown plugin_version fails closed under --require-tool" "re-review with 3.0.0" "$v"
jqedit "$f" 'del(.plugin_version)'
v=$(verify "$r" --require-tool ultra-audit)
check "a missing plugin_version fails closed under --require-tool" "re-review with 3.0.0" "$v"
jqedit "$f" '.plugin_version = "10.0.0"'
v=$(verify "$r" --require-tool ultra-audit)
check "a two-digit major passes --require-tool" "PASS: GO receipt" "$v"
# A newer 3.x GO out-ranks an older 2.x GO; a newer 2.x GO does not inherit
# an older 3.x pass.
r=$(newrepo)
f1=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
jqedit "$f1" '.plugin_version = "2.10.0"'
emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r" --require-tool ultra-audit)
check "a newer 3.x GO supersedes an older 2.x GO" "PASS: GO receipt" "$v"
f3=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
jqedit "$f3" '.plugin_version = "2.9.1"'
v=$(verify "$r" --require-tool ultra-audit)
check "a newer 2.x GO is refused even over an older 3.x GO" "re-review with 3.0.0" "$v"
# Same-second tie: a 2.x GO loses to nothing but out-ranks a clean 3.x GO.
r=$(newrepo)
f1=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
f2=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0 | grep -o '/.*\.json' | head -1)
ts=$(jq -r .emitted_at "$f2")
jqedit "$f1" --arg t "$ts" '.emitted_at = $t | .plugin_version = "2.10.0"'
v=$(verify "$r" --require-tool ultra-audit)
check "a tied 2.x GO fails closed under --require-tool" "re-review with 3.0.0" "$v"

# --- 35. a newer NO-GO that lost its fingerprint still blocks (R0) ------------
r=$(newrepo)
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
f=$(emit "$r" --verdict NO-GO | grep -o '/.*\.json' | head -1)
jqedit "$f" 'del(.fingerprint)'
v=$(verify "$r")
check "a fingerprint-less newer NO-GO shadows the GO" "verdict NO-GO" "$v"
check "the fingerprint-less NO-GO exits 1" "code=1" "$v"
jqedit "$f" '.fingerprint = ""'
v=$(verify "$r")
check "an empty-fingerprint newer NO-GO shadows the GO" "verdict NO-GO" "$v"
( cd "$r" && printf 'more\n' >> feat.txt && git add -A && git commit -qm more ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
v=$(verify "$r")
check "a fingerprint-less NO-GO for another head does not block" "PASS: GO receipt" "$v"
# A dirty-tree NO-GO without its fingerprint still blocks a dirty-tree GO
# on the same head (the GO matches on the worktree fingerprint).
r=$(newrepo)
( cd "$r" && printf 'wip\n' > wip.txt ) >/dev/null 2>&1
emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0 >/dev/null
f=$(emit "$r" --verdict NO-GO | grep -o '/.*\.json' | head -1)
check "the dirty NO-GO records a dirty tree" '"tree_state": "dirty"' "$(cat "$f")"
jqedit "$f" 'del(.fingerprint)'
v=$(verify "$r")
check "a fingerprint-less dirty-tree NO-GO shadows the dirty GO" "verdict NO-GO" "$v"

# --- 36. --require-tool filters PR-comment receipts too ------------------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
out=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=0,low=0)
fcr=$(grep -o '/.*\.json' <<<"$out" | head -1)
GH_STUB_FAIL=0
publish "$r" --pr 7 --file "$fcr" >/dev/null
GH_STUB_FAIL=1
rm -f "$r/.git/ultra-audit/receipts/"*.json "$r/.git/chad-review/receipts/"*.json 2>/dev/null
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7 --require-tool ultra-audit)
GH_STUB_FAIL=1
check "a published chad-review GO does not satisfy --require-tool ultra-audit" "no ultra-audit receipt found" "$v"
check "the PR-comment require-tool miss exits 1" "code=1" "$v"
out=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0)
fua=$(grep -o '/.*\.json' <<<"$out" | head -1)
GH_STUB_FAIL=0
publish "$r" --pr 7 --file "$fua" >/dev/null
GH_STUB_FAIL=1
rm -f "$r/.git/ultra-audit/receipts/"*.json "$r/.git/chad-review/receipts/"*.json 2>/dev/null
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7 --require-tool ultra-audit)
GH_STUB_FAIL=1
check "a published ultra-audit GO satisfies --require-tool ultra-audit" "PASS: GO receipt (github)" "$v"

# --- 37. the no-args usage names --require-tool (merge-gate.sh detects it) ----
v=$( ( bash "$SCRIPT" 2>&1 ); echo "code=$?" )
check "usage names --require-tool" "--require-tool" "$v"
check "no-args usage exits 2" "code=2" "$v"

# --- 38. nothing ahead of the base: emit refuses, writes no receipt -----------
r=$(newrepo)
( cd "$r" && git checkout -q main ) >/dev/null 2>&1
out=$(emit "$r" --tool ultra-audit --verdict GO --counts critical=0,high=0,medium=0,low=0); rc=$?
check "an empty diff has nothing to gate" "the diff against" "$out"
expect_code "empty-diff emit exits 2" "2" "$rc"
n=$(ls -1 "$r/.git/ultra-audit/receipts" 2>/dev/null | grep -c '\.json$' || true)
expect_code "empty-diff emit wrote no receipt" "0" "$n"

echo
echo "receipt.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
