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
# closed; and a receipt emitted on a dirty tree still matches after the exact
# same content is committed (the untracked fold-in equivalence, verified here
# by running the real code, not on paper).
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
  if grep -qF "$2" <<<"$3"; then ok "$1"; else
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
    method=GET; path=""; bodyfile=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -X) method="$2"; shift 2 ;;
        --paginate) shift ;;
        -f) v="$2"; bodyfile="${v#body=@}"; shift 2 ;;
        repos/*) path="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [[ "$method" == "GET" ]]; then
      cat "$GH_STUB_DIR/comments.json"
    else
      id="${path##*/}"
      jq --rawfile b "$bodyfile" --argjson id "$id" \
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

# --- 1. emit on a clean tree, verify the exact head ---------------------------
r=$(newrepo)
out=$(emit "$r" --verdict GO --counts critical=0,high=0,medium=1,low=0)
check "emit prints an absolute receipt path" "$r/.git/chad-review/receipts/" "$out"
f=$(grep -o '/.*\.json' <<<"$out" | head -1)
if jq -e . "$f" >/dev/null 2>&1; then ok "the receipt is valid JSON"; else bad "the receipt is valid JSON"; fi
check "receipt records the verdict" '"verdict": "GO"' "$(cat "$f")"
check "receipt records the plugin version" '"plugin_version": "2.4.0"' "$(cat "$f")"
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
emit "$r" --verdict GO >/dev/null
( cd "$r" && git checkout -q main \
  && sed -e 's/line6/line6 changed by main/' base.txt > b.tmp && mv b.tmp base.txt \
  && git add -A && git commit -qm touch6 && git push -q origin main \
  && git checkout -q feat && git rebase -q main ) >/dev/null 2>&1
v=$(verify "$r")
check "near-hunk rebase fails closed" "FAIL: receipt(s) found but stale" "$v"
check "near-hunk rebase exits 1" "code=1" "$v"

# --- 4. any substantive change after the receipt is stale ----------------------
r=$(newrepo)
emit "$r" --verdict GO >/dev/null
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
emit "$r" --verdict GO >/dev/null
emit "$r" --verdict NO-GO >/dev/null
v=$(verify "$r")
check "newest ruling for the content wins" "verdict NO-GO" "$v"

# --- 7. no receipt at all --------------------------------------------------------
r=$(newrepo)
v=$(verify "$r")
check "missing receipt fails" "FAIL: no valid chad-review receipt" "$v"
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
check "a look-alike review comment never passes" "FAIL: no valid chad-review receipt" "$v"

# --- 9. dirty-tree emit (untracked files), commit verbatim, verify ---------------
r=$(newrepo)
( cd "$r" && printf 'new file\n' > extra.txt && : > empty.txt \
  && printf '#!/bin/sh\ntrue\n' > tool.sh && chmod 755 tool.sh ) >/dev/null 2>&1
out=$(emit "$r" --verdict GO)
check "dirty emit records tree state" '"tree_state": "dirty"' "$(cat "$(grep -o '/.*\.json' <<<"$out" | head -1)")"
( cd "$r" && git add -A && git commit -qm addall ) >/dev/null 2>&1
v=$(verify "$r")
check "untracked fold-in survives the commit" "PASS: GO receipt" "$v"
check "fold-in match is convergence" "(convergence)" "$v"

# --- 10. dirty-tree emit (modified tracked file), commit verbatim ----------------
r=$(newrepo)
( cd "$r" && printf 'edited\n' >> base.txt ) >/dev/null 2>&1
emit "$r" --verdict GO >/dev/null
( cd "$r" && git add -A && git commit -qm edit ) >/dev/null 2>&1
v=$(verify "$r")
check "modified-tracked fold-in survives the commit" "PASS: GO receipt" "$v"

# --- 11. a dirty receipt's head_sha never counts as exact-head --------------------
r=$(newrepo)
( cd "$r" && printf 'edited\n' >> base.txt ) >/dev/null 2>&1
emit "$r" --verdict GO >/dev/null
( cd "$r" && git checkout -q -- base.txt ) >/dev/null 2>&1
v=$(verify "$r")
check "discarded dirty content is stale, not exact-head" "FAIL: receipt(s) found but stale" "$v"

# --- 12. binary content changes re-arm via --full-index ---------------------------
r=$(newrepo)
( cd "$r" && printf '\x00\x01\x02\x80\xff' > blob.bin && git add -A && git commit -qm bin ) >/dev/null 2>&1
emit "$r" --verdict GO >/dev/null
( cd "$r" && printf '\x00\x01\x03\x80\xff' > blob.bin && git add -A && git commit -qm bin2 ) >/dev/null 2>&1
v=$(verify "$r")
check "a binary byte flip is stale" "FAIL: receipt(s) found but stale" "$v"

# --- 13. publish is idempotent: one create, then update-in-place ------------------
r=$(newrepo)
h=$(cd "$r" && git rev-parse HEAD)
reset_gh "$h"
emit "$r" --verdict GO >/dev/null
GH_STUB_FAIL=0
p1=$(publish "$r" --pr 7); p2=$(publish "$r" --pr 7)
GH_STUB_FAIL=1
check "first publish creates the comment" "published: new receipt comment" "$p1"
check "second publish updates in place" "published: updated receipt comment" "$p2"
n=$(jq 'length' "$GH_STUB_DIR/comments.json")
expect_code "exactly one receipt comment exists" "1" "$n"
check "the comment carries the marker" "chad-review-receipt v1" "$(jq -r '.[0].body' "$GH_STUB_DIR/comments.json")"

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
emit "$r" --verdict GO >/dev/null
GH_STUB_FAIL=0 GH_STUB_AUTHOR=NONE publish "$r" --pr 7 >/dev/null
rm -f "$(store_of "$r")"/*.json
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "an untrusted author's receipt does not count" "FAIL: no valid chad-review receipt" "$v"

# --- 16. gh unavailable degrades to local-only with a warning ---------------------
r=$(newrepo)
emit "$r" --verdict GO >/dev/null
v=$(verify "$r" --pr 7)   # GH_STUB_FAIL=1 is the ambient default
check "gh-less verify warns" "WARN: local-only verification" "$v"
check "gh-less verify still passes on the local receipt" "PASS: GO receipt (local)" "$v"

# --- 17. no origin remote: path identity, local flow works ------------------------
d="$WORKDIR/noorigin"; mkdir -p "$d"
( cd "$d" && git init -q -b main . && printf 'x\n' > f.txt && git add -A && git commit -qm base \
  && git checkout -qb feat && printf 'y\n' > g.txt && git add -A && git commit -qm feat ) >/dev/null 2>&1
out=$(emit "$d" --verdict GO --base main)
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
out=$(emit "$d" --verdict GO)
check "origin/master is found without a flag" '"base_ref": "origin/master"' "$(cat "$(grep -o '/.*\.json' <<<"$out" | head -1)")"
d="$WORKDIR/trunk"; mkdir -p "$d"
( cd "$d" && git init -q -b trunk . && printf 'x\n' > f.txt && git add -A && git commit -qm base \
  && git checkout -qb feat && printf 'y\n' > g.txt && git add -A && git commit -qm feat ) >/dev/null 2>&1
v=$( ( cd "$d" && bash "$SCRIPT" verify 2>&1 ); echo "code=$?" )
check "no resolvable base is a cannot-run" "CANNOT-RUN: no base ref" "$v"
check "cannot-run exits 2" "code=2" "$v"

# --- 19. two branches share the store without shadowing each other ----------------
r=$(newrepo)
emit "$r" --verdict GO >/dev/null
( cd "$r" && git checkout -q main && git checkout -qb feat2 \
  && printf 'z\n' > z.txt && git add -A && git commit -qm feat2 ) >/dev/null 2>&1
emit "$r" --verdict GO >/dev/null
v2=$(verify "$r")
( cd "$r" && git checkout -q feat ) >/dev/null 2>&1
v1=$(verify "$r")
check "second branch verifies on its own receipt" "PASS: GO receipt" "$v2"
check "first branch still verifies after the second emitted" "PASS: GO receipt" "$v1"

# --- 20. verify refuses a local HEAD that is not the PR head ----------------------
r=$(newrepo)
emit "$r" --verdict GO >/dev/null
reset_gh "0000000000000000000000000000000000000000"
GH_STUB_FAIL=0
v=$(verify "$r" --pr 7)
GH_STUB_FAIL=1
check "PR head mismatch fails" "is not the PR head" "$v"
check "PR head mismatch exits 1" "code=1" "$v"

# --- 21. the store prunes to the newest 20 ----------------------------------------
r=$(newrepo)
i=1; while [[ $i -le 25 ]]; do emit "$r" --verdict GO >/dev/null; i=$((i+1)); done
n=$(ls -1 "$(store_of "$r")" | grep -c '\.json$')
expect_code "25 emits leave 20 receipts" "20" "$n"

# --- 22. a corrupt receipt fails closed, never crashes ----------------------------
r=$(newrepo)
mkdir -p "$(store_of "$r")"
printf '{"schema": "chad-review-receipt", "schema_version": 1, "tool": "chad-review", "verdict": "GO", "head_sha": "abc"}\n' \
  > "$(store_of "$r")/20260731T120000Z-corrupt.json"
printf 'not json at all\n' > "$(store_of "$r")/20260731T120001Z-junk.json"
v=$(verify "$r")
check "a receipt missing its fingerprint does not count" "FAIL: no valid chad-review receipt" "$v"
check "corrupt candidates exit 1, not a crash" "code=1" "$v"

echo
echo "receipt.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
