#!/usr/bin/env bash
# receipt.sh: durable, machine-checkable proof that a chad-review or
# ultra-audit review covered exactly this diff.
#
# WHY THIS EXISTS
# The merge gate ("a chad-review ran against the PR head") used to be enforced
# by session memory and prose: a wrap-up flow would "confirm a review ran this
# session", which a hand-rolled reviewer, a stale review of an older diff, or
# an optimistic recollection could all satisfy. One hand-rolled copy of the
# review skipped a whole pass and merged 59 CVEs. Nothing durable tied the
# verdict to the content it judged.
#
# A receipt binds verdict to content: the reviewed HEAD sha plus a stable
# fingerprint of the diff against the merge base. `verify` then passes ONLY
# when the current content is provably what was reviewed:
#   - the exact reviewed head (receipt taken on a clean tree), or
#   - the same fingerprint (a clean rebase moves the sha but not the patch-id,
#     so an unchanged PR diff converges without a re-review). verify computes
#     BOTH the head-mode and worktree-mode fingerprints and matches either, so
#     a receipt emitted from a dirty tree (untracked files folded in) verifies
#     without any flag as long as the tree content is unchanged; verify used to
#     default to head-mode only and falsely reported such receipts stale.
# Anything else fails closed: a changed diff, a NO-GO or CONDITIONAL verdict,
# a missing receipt, a receipt for another repo or base, or a PR comment that
# merely looks like a review. A generic reviewer cannot satisfy the gate by
# accident, because a candidate must carry one of the two schema/tool pairs
# (chad-review-receipt with chad-review, or ultra-audit-receipt with
# ultra-audit) and a fingerprint that matches the diff being merged. Either
# tool's receipt satisfies the gate; the newest ruling for the current
# content wins across both.
#
# THE FINGERPRINT
# `git patch-id --stable` over the merge-base diff, with every diff knob
# pinned (prefixes, renames, algorithm, --full-index) so emit and verify can
# never disagree via user git config. Properties, verified on git 2.50:
#   - hunk offsets and hunk-header context are ignored: a clean rebase with an
#     unchanged diff keeps its patch-id;
#   - context lines are hashed: a rebase that lands a main-side change within
#     3 lines of a PR hunk re-arms the gate (conservative, correct);
#   - --full-index makes binary changes re-arm via the full index line;
#   - whitespace-only edits do NOT re-arm (the same property git itself uses
#     for cherry/rebase equivalence); accepted and documented.
# On a dirty tree, untracked files fold in as `git diff --no-index /dev/null
# <f>` patches, which are byte-identical in shape to the committed new-file
# diff, so a receipt emitted before `git add` still matches after the commit.
#
# DURABILITY
# Local stores: <git-common-dir>/<tool>/receipts/, one per tool (shared across
# worktrees, survives worktree teardown, never committed; newest 20 kept per
# store). emit writes to its own tool's store; verify scans both.
# GitHub: one idempotent PR comment carrying the marker and the receipt JSON,
# so a different session or machine can verify without this filesystem.
# `verify` takes the union and trusts the newest ruling FOR THE CURRENT
# CONTENT; an old GO on byte-identical content is correct by definition, and
# a NO-GO re-review of unchanged content out-ranks an older GO on it.
#
# USAGE
#   receipt.sh emit    --verdict GO|NO-GO|CONDITIONAL [--base <ref>] [--pr <n>]
#                      [--counts critical=0,high=0,medium=0,low=0]
#   receipt.sh publish [--pr <n>] [--file <receipt.json>]
#   receipt.sh verify  [--base <ref>] [--pr <n>] [--worktree]
#
# emit writes the receipt and prints its absolute path; with --pr and a
# working gh it also publishes. publish posts or updates the PR comment.
# verify exits 0 on PASS (reason on stdout), 1 on a gate failure (reason on
# stdout), 2 when it cannot run at all (not a repo, no jq, no base).
#
# gh surface is exactly four shapes, so tests can stub it: `gh pr view
# [--json ...]`, `gh api repos/<r>/issues/<n>/comments --paginate`,
# `gh api -X PATCH repos/<r>/issues/comments/<id> -f body=@<file>`, and
# `gh pr comment <n> --body-file <file>`.
#
# BASH 3.2 (no associative arrays, no mapfile); BSD grep/sed. jq is required
# for publish and verify (they parse JSON); emit writes its JSON with printf
# and needs neither jq nor gh.
set -uo pipefail

MARKER='<!-- chad-review-receipt v1 -->'
MARKER_UA='<!-- ultra-audit-receipt v1 -->'
STORE_KEEP=20

usage() {
  echo "usage: receipt.sh emit --verdict GO|NO-GO|CONDITIONAL [--tool chad-review|ultra-audit] [--base <ref>] [--pr <n>] [--counts critical=0,high=0,medium=0,low=0]" >&2
  echo "       receipt.sh publish [--pr <n>] [--file <receipt.json>]" >&2
  echo "       receipt.sh verify [--base <ref>] [--pr <n>] [--worktree]" >&2
  exit 2
}

cannot() { echo "CANNOT-RUN: $*"; exit 2; }

# Every diff knob pinned. User config (diff.noprefix, mnemonicPrefix,
# external drivers, algorithm) must not be able to make emit and verify
# disagree about the same content.
GITDIFF=(git -c core.quotepath=false -c diff.noprefix=false
         -c diff.mnemonicPrefix=false -c diff.srcPrefix=a/ -c diff.dstPrefix=b/
         -c diff.relative=false
         diff --no-color --no-ext-diff --no-textconv --no-renames
              --full-index --diff-algorithm=myers)

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

repo_identity() {
  local u
  u=$(git remote get-url origin 2>/dev/null)
  if [[ -z "$u" ]]; then git rev-parse --show-toplevel 2>/dev/null; return 0; fi
  u=${u%/}; u=${u%.git}
  case "$u" in
    git@*:*)            u=${u#git@}; u=${u#*:} ;;
    ssh://*)            u=${u#ssh://}; u=${u#git@}; u=${u#*/} ;;
    http://*|https://*) u=${u#http*://}; u=${u#*/} ;;
  esac
  printf '%s\n' "$u"
}

resolve_base() { # uses $base_flag; prints the ref or returns 1
  local b
  if [[ -n "$base_flag" ]]; then printf '%s\n' "$base_flag"; return 0; fi
  b=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$b" ]]; then printf '%s\n' "$b"; return 0; fi
  for b in origin/main origin/master main master; do
    if git rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$b"; return 0
    fi
  done
  return 1
}

store_dir() {
  local d
  d=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [[ -z "$d" ]]; then
    d=$(git rev-parse --git-common-dir 2>/dev/null || true)
    [[ -n "$d" ]] && d=$(cd "$d" 2>/dev/null && pwd)
  fi
  [[ -n "$d" ]] || return 1
  printf '%s/%s/receipts\n' "$d" "${1:-chad-review}"
}

# fingerprint <head|worktree> <merge-base> : prints patchid-v1:<sha>, or
# nothing when the diff is empty. `git diff --no-index` exits 1 whenever the
# files differ, which is its success case here; without the explicit `|| true`
# a future `set -e` edit would break exactly this line first.
fingerprint() {
  local mode="$1" mb="$2" out
  if [[ "$mode" == "head" ]]; then
    out=$("${GITDIFF[@]}" "$mb" HEAD 2>/dev/null | git patch-id --stable | cut -d' ' -f1)
  else
    out=$({ "${GITDIFF[@]}" "$mb" 2>/dev/null
            git -c core.quotepath=false ls-files -z --others --exclude-standard 2>/dev/null \
            | while IFS= read -r -d '' f; do
                "${GITDIFF[@]}" --no-index -- /dev/null "$f" 2>/dev/null || true
              done
          } | git patch-id --stable | cut -d' ' -f1)
  fi
  [[ -n "$out" ]] && printf 'patchid-v1:%s\n' "$out"
  return 0
}

plugin_version() {
  local pj v=""
  pj="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.claude-plugin/plugin.json"
  if [[ -f "$pj" ]]; then
    if command -v jq >/dev/null 2>&1; then
      v=$(jq -r '.version // empty' "$pj" 2>/dev/null)
    fi
    [[ -z "$v" ]] && v=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$pj" 2>/dev/null | head -1)
  fi
  printf '%s\n' "${v:-unknown}"
}

require_repo_head() {
  git rev-parse --git-dir >/dev/null 2>&1 || cannot "not a git repository"
  git rev-parse -q --verify HEAD >/dev/null 2>&1 || cannot "no commits yet; nothing reviewable has a merge base"
}

# --- emit --------------------------------------------------------------------

do_emit() {
  local verdict="" counts="" pr="" tool="chad-review"
  base_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verdict) verdict="${2:-}"; shift 2 || usage ;;
      --tool)    tool="${2:-}"; shift 2 || usage ;;
      --base)    base_flag="${2:-}"; shift 2 || usage ;;
      --pr)      pr="${2:-}"; shift 2 || usage ;;
      --counts)  counts="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  case "$verdict" in GO|NO-GO|CONDITIONAL) ;; *) usage ;; esac
  case "$tool" in chad-review|ultra-audit) ;; *) usage ;; esac
  [[ -n "$pr" && ! "$pr" =~ ^[0-9]+$ ]] && usage

  local c_critical=0 c_high=0 c_medium=0 c_low=0 part
  if [[ -n "$counts" ]]; then
    while IFS= read -r part; do
      [[ -z "$part" ]] && continue
      case "$part" in
        critical=*|high=*|medium=*|low=*)
          [[ "${part#*=}" =~ ^[0-9]+$ ]] || usage
          eval "c_${part%%=*}=${part#*=}" ;;
        *) usage ;;
      esac
    done < <(printf '%s\n' "$counts" | tr ',' '\n')
  fi

  require_repo_head
  local base mb head tree untracked fpmode fp store ts file n repo top
  base=$(resolve_base) || cannot "no base ref resolvable; pass --base"
  git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || cannot "base ref $base does not resolve"
  mb=$(git merge-base "$base" HEAD 2>/dev/null || true)
  [[ -n "$mb" ]] || cannot "no merge base between $base and HEAD"
  head=$(git rev-parse HEAD)
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then tree=dirty; else tree=clean; fi
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)
  if [[ "$tree" == dirty ]]; then fpmode=worktree; else fpmode=head; fi
  fp=$(fingerprint "$fpmode" "$mb")
  [[ -n "$fp" ]] || cannot "nothing to fingerprint: the diff against $base is empty"

  store=$(store_dir "$tool") || cannot "cannot locate the git common dir"
  mkdir -p "$store" && chmod 700 "$store" 2>/dev/null
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  file="$store/$ts-$(printf '%.12s' "$head").json"
  n=1
  while [[ -e "$file" ]]; do
    file="$store/$ts-$(printf '%.12s' "$head")-$n.json"; n=$((n+1))
  done

  repo=$(repo_identity)
  top=$(git rev-parse --show-toplevel)
  local schema="chad-review-receipt"
  [[ "$tool" == "ultra-audit" ]] && schema="ultra-audit-receipt"
  {
    printf '{\n'
    printf '  "schema": "%s",\n' "$schema"
    printf '  "schema_version": 1,\n'
    printf '  "tool": "%s",\n' "$tool"
    printf '  "plugin_version": "%s",\n' "$(json_str "$(plugin_version)")"
    printf '  "repo": "%s",\n' "$(json_str "$repo")"
    printf '  "repo_path": "%s",\n' "$(json_str "$top")"
    printf '  "pr": %s,\n' "${pr:-null}"
    printf '  "base_ref": "%s",\n' "$(json_str "$base")"
    printf '  "base_sha": "%s",\n' "$(git rev-parse "$base")"
    printf '  "merge_base": "%s",\n' "$mb"
    printf '  "head_sha": "%s",\n' "$head"
    printf '  "tree_state": "%s",\n' "$tree"
    printf '  "untracked_count": %s,\n' "${untracked:-0}"
    printf '  "fingerprint": "%s",\n' "$fp"
    printf '  "verdict": "%s",\n' "$verdict"
    printf '  "findings": { "critical": %s, "high": %s, "medium": %s, "low": %s },\n' \
      "$c_critical" "$c_high" "$c_medium" "$c_low"
    printf '  "emitted_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } > "$file"

  # Prune to the newest STORE_KEEP by name; the timestamp prefix makes
  # name-sort time-sort (the untracked-guard rotation precedent).
  local old
  while IFS= read -r old; do
    [[ -n "$old" ]] && rm -f "$store/$old"
  done < <(ls -1 "$store" 2>/dev/null | LC_ALL=C sort -r | tail -n +$((STORE_KEEP + 1)))

  printf '%s\n' "$file"

  if [[ -n "$pr" ]]; then
    if do_publish --pr "$pr" --file "$file"; then :; else
      echo "WARN: receipt written locally; publish to PR #$pr failed (gh unavailable?)"
    fi
  fi
  return 0
}

# --- publish -------------------------------------------------------------------

do_publish() {
  local pr="" file="" repo store f id tmp head fp verdict base sd best_base=""
  base_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)   pr="${2:-}"; shift 2 || usage ;;
      --file) file="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || cannot "publish needs jq"
  command -v gh >/dev/null 2>&1 || { echo "FAIL: publish needs gh"; return 1; }
  require_repo_head
  git remote get-url origin >/dev/null 2>&1 \
    || { echo "FAIL: no origin remote; nothing to publish to"; return 1; }
  repo=$(repo_identity)

  if [[ -z "$pr" ]]; then
    pr=$(gh pr view --json number --jq .number 2>/dev/null || true)
    [[ -n "$pr" ]] || { echo "FAIL: no PR found for this branch; pass --pr"; return 1; }
  fi

  if [[ -z "$file" ]]; then
    # Newest local receipt for this repo across both tool stores, whatever the
    # branch: the caller who wants precision passes --file (emit does exactly
    # that). The timestamp filename prefix makes the basename comparison a
    # time comparison.
    for sd in chad-review ultra-audit; do
      store=$(store_dir "$sd") || cannot "cannot locate the git common dir"
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if jq -e --arg r "$repo" \
            '(.schema == "chad-review-receipt" or .schema == "ultra-audit-receipt") and .repo == $r' \
            "$store/$f" >/dev/null 2>&1; then
          if [[ -z "$best_base" || "$f" > "$best_base" ]]; then
            best_base="$f"; file="$store/$f"
          fi
          break
        fi
      done < <(ls -1 "$store" 2>/dev/null | LC_ALL=C sort -r)
    done
    [[ -n "$file" ]] || { echo "FAIL: no local receipt to publish; run emit first"; return 1; }
  fi
  jq -e . "$file" >/dev/null 2>&1 || { echo "FAIL: $file is not valid JSON"; return 1; }

  head=$(jq -r .head_sha "$file"); fp=$(jq -r .fingerprint "$file")
  verdict=$(jq -r .verdict "$file"); base=$(jq -r .base_ref "$file")
  local pub_tool pub_marker pub_label
  pub_tool=$(jq -r '.tool // "chad-review"' "$file")
  pub_marker="$MARKER"
  pub_label="chad-review receipt"
  if [[ "$pub_tool" == "ultra-audit" ]]; then
    pub_marker="$MARKER_UA"
    pub_label="ultra-audit receipt"
  fi
  tmp=$(mktemp)
  {
    printf '%s\n' "$pub_marker"
    printf '%s: **%s** for `%.12s` (fingerprint `%s`, base %s)\n\n' \
      "$pub_label" "$verdict" "$head" "$fp" "$base"
    printf '```json\n'
    cat "$file"
    printf '```\n'
  } > "$tmp"

  # Update-in-place: one canonical receipt comment per PR. `gh pr comment
  # --edit-last` is rejected on purpose (it edits whatever your last comment
  # was, receipt or not).
  id=$(gh api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null \
    | jq -rs --arg m "$pub_marker" '[.[] | .[]?
        | select((.body | contains($m))
            and (.author_association == "OWNER" or .author_association == "MEMBER"
                 or .author_association == "COLLABORATOR"))][0].id // empty' 2>/dev/null)
  if [[ -n "$id" ]]; then
    if gh api -X PATCH "repos/$repo/issues/comments/$id" -f "body=@$tmp" >/dev/null 2>&1; then
      echo "published: updated receipt comment $id on PR #$pr"
    else
      rm -f "$tmp"; echo "FAIL: could not update receipt comment on PR #$pr"; return 1
    fi
  else
    if gh pr comment "$pr" --body-file "$tmp" >/dev/null 2>&1; then
      echo "published: new receipt comment on PR #$pr"
    else
      rm -f "$tmp"; echo "FAIL: could not comment on PR #$pr"; return 1
    fi
  fi
  rm -f "$tmp"
  return 0
}

# --- verify ---------------------------------------------------------------------

# stdin: one receipt JSON. stdout: one TSV candidate row, or nothing when the
# document is not a structurally valid receipt from either tool. This filter is
# the "generic reviews never pass" rule: no marker schema, no candidacy, and
# the schema must pair with its own tool (a mismatched pair is a forgery, not
# a receipt).
candidate_row() {
  jq -r --arg src "$1" '
    select(type == "object")
    | select(.schema_version == 1)
    | select((.schema == "chad-review-receipt" and .tool == "chad-review")
             or (.schema == "ultra-audit-receipt" and .tool == "ultra-audit"))
    | select(((.fingerprint // "") != "") and ((.head_sha // "") != "") and ((.verdict // "") != ""))
    | [(.emitted_at // "0"), $src, .verdict, .head_sha, (.tree_state // "clean"),
       .fingerprint, (.repo // "-"), (.base_ref // "-"),
       (((.findings.critical // 0) + (.findings.high // 0)) | tostring)]
    | @tsv' 2>/dev/null
  return 0
}

do_verify() {
  local pr=""
  base_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)       pr="${2:-}"; shift 2 || usage ;;
      --base)     base_flag="${2:-}"; shift 2 || usage ;;
      --worktree) shift ;;   # accepted for back-compat; both modes always run now
      *) usage ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || cannot "verify needs jq"
  require_repo_head

  local base mb cur_head cur_fp_head cur_fp_wt repo store sd f rows gh_ok=0 prhead block
  base=$(resolve_base) || cannot "no base ref resolvable; pass --base"
  git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || cannot "base ref $base does not resolve"
  mb=$(git merge-base "$base" HEAD 2>/dev/null || true)
  [[ -n "$mb" ]] || cannot "no merge base between $base and HEAD"
  cur_head=$(git rev-parse HEAD)
  # Both modes, always: a receipt emitted from a dirty tree carries a
  # worktree-mode fingerprint, one from a clean tree a head-mode one, and the
  # verifier cannot know which kind it is about to meet. On a clean tree the
  # two computations produce the same patch-id, so the extra one is free.
  cur_fp_head=$(fingerprint head "$mb")
  cur_fp_wt=$(fingerprint worktree "$mb")
  repo=$(repo_identity)

  # A PR gate must judge the head that will merge. A local checkout behind or
  # ahead of the PR head would otherwise verify the wrong content.
  if [[ -n "$pr" ]]; then
    if command -v gh >/dev/null 2>&1 \
       && prhead=$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null) \
       && [[ -n "$prhead" ]]; then
      gh_ok=1
      if [[ "$prhead" != "$cur_head" ]]; then
        echo "FAIL: local HEAD $cur_head is not the PR head $prhead; push or fetch first"
        return 1
      fi
    else
      echo "WARN: local-only verification; receipt not confirmed on the PR (gh unavailable)"
    fi
  fi

  rows=""
  for sd in chad-review ultra-audit; do
    store=$(store_dir "$sd" 2>/dev/null || true)
    if [[ -n "$store" && -d "$store" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rows+=$(candidate_row local < "$store/$f")$'\n'
      done < <(ls -1 "$store" 2>/dev/null)
    fi
  done
  if [[ -n "$pr" && "$gh_ok" == 1 ]]; then
    # Receipts published to the PR: jq pulls the fenced JSON out of each
    # trusted marker comment and strips its newlines, which keeps it valid
    # JSON (a raw newline cannot occur inside a JSON string) while making one
    # receipt one shell line. Cross-machine truth lives here.
    while IFS= read -r block; do
      [[ -z "$block" ]] && continue
      rows+=$(printf '%s' "$block" | candidate_row github)$'\n'
    done < <(gh api "repos/$repo/issues/$pr/comments" --paginate 2>/dev/null \
      | jq -rs --arg m "$MARKER" --arg m2 "$MARKER_UA" '.[] | .[]?
          | select(((.body | contains($m)) or (.body | contains($m2)))
              and (.author_association == "OWNER" or .author_association == "MEMBER"
                   or .author_association == "COLLABORATOR"))
          | (.body | split("```json\n")[1] // "" | split("\n```")[0] // "" | gsub("\n"; ""))' 2>/dev/null)
  fi

  rows=$(printf '%s' "$rows" | grep -v '^$' || true)
  if [[ -z "$rows" ]]; then
    echo "FAIL: no valid review receipt found (chad-review or ultra-audit; local store or PR comments)"
    return 1
  fi

  local scoped
  scoped=$(printf '%s\n' "$rows" | awk -F'\t' -v r="$repo" -v b="$base" '$7 == r && $8 == b')
  if [[ -z "$scoped" ]]; then
    echo "FAIL: receipts exist, but none for repo $repo with base $base"
    return 1
  fi

  local matches best verdict src how
  matches=$(printf '%s\n' "$scoped" | awk -F'\t' -v h="$cur_head" -v fph="$cur_fp_head" -v fpw="$cur_fp_wt" \
    '($5 == "clean" && $4 == h) || (fph != "" && $6 == fph) || (fpw != "" && $6 == fpw)')
  if [[ -z "$matches" ]]; then
    echo "FAIL: receipt(s) found but stale: the diff changed since the review"
    return 1
  fi

  # Newest ruling for THIS content wins. On an emitted_at tie, fail closed: a
  # non-GO ruling at the newest timestamp out-ranks a GO at the same instant
  # (with two tool stores merged, same-second emits are reachable, and the
  # bare whole-line sort fallback would otherwise let GO win by lexical
  # accident). Among tied rows of the same verdict, the GitHub copy wins
  # (github < local sorts first).
  local newest_ts tie_nogo blockers
  best=$(printf '%s\n' "$matches" | LC_ALL=C sort -t"$(printf '\t')" -k1,1r -k2,2 | head -1)
  newest_ts=$(printf '%s' "$best" | cut -f1)
  tie_nogo=$(printf '%s\n' "$matches" | awk -F'\t' -v t="$newest_ts" '$1 == t && $3 != "GO"' \
    | LC_ALL=C sort -t"$(printf '\t')" -k2,2 | head -1)
  [[ -n "$tie_nogo" ]] && best="$tie_nogo"
  verdict=$(printf '%s' "$best" | cut -f3)
  src=$(printf '%s' "$best" | cut -f2)
  if [[ "$verdict" != "GO" ]]; then
    echo "FAIL: newest receipt for this content has verdict $verdict"
    return 1
  fi
  # A GO that records unfixed critical or high findings contradicts both
  # tools' verdict mapping (nodes/receipt.md, chad-review verdict rules);
  # enforce that contract mechanically rather than trusting the emitter.
  blockers=$(printf '%s' "$best" | cut -f9)
  if [[ -n "$blockers" && "$blockers" != "0" ]]; then
    echo "FAIL: newest receipt is GO but records $blockers critical/high finding(s); re-review"
    return 1
  fi
  if [[ "$(printf '%s' "$best" | cut -f5)" == "clean" && "$(printf '%s' "$best" | cut -f4)" == "$cur_head" ]]; then
    how=exact-head
  else
    how=convergence
  fi
  echo "PASS: GO receipt ($src) covers $cur_head ($how)"
  return 0
}

# --- dispatch --------------------------------------------------------------------

[[ $# -ge 1 ]] || usage
cmd="$1"; shift
case "$cmd" in
  emit)    do_emit "$@" ;;
  publish) do_publish "$@" ;;
  verify)  do_verify "$@" ;;
  *) usage ;;
esac
