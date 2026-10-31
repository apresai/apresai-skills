# Node: receipt

Every completed run emits one, whatever the outcome, with one exception: no
commits ahead of the base and a clean tree is nothing to gate
(`receipt.sh` refuses an empty diff), so that run says so and emits none.

Emit last, from the real branch worktree, after `pr-stage.sh check` and
`pr-stage.sh remove`. The staged worktree shares the same receipt store (same
git common dir), but its `HEAD` is the merge base, and `receipt.sh` writes the
`head_sha` it is run on; only the real worktree carries the branch head the
merge gate checks.

**Counts come from the ledger**, never typed by hand: this run's `open`
entries by severity, taking the newest line per finding (`nodes/verify.md`
§ Ledger). A missing or unrecognized
severity counts as `high`, so a malformed entry can never vanish from the
count. This prints all four keys, zeros included, and all zeros when the
ledger is missing:

```bash
LEDGER=<LEDGER= path>; RUN=<this run's number>
if [ -s "$LEDGER" ]; then
  jq -rs --argjson r "$RUN" '[.[] | select(.run == $r)] | group_by([.file, .line, .finding]) | map(last) | [.[] | select(.outcome == "open") | ((.severity // "high") | ascii_downcase | if IN("critical","high","medium","low") then . else "high" end)] as $s | "critical=\($s | map(select(. == "critical")) | length),high=\($s | map(select(. == "high")) | length),medium=\($s | map(select(. == "medium")) | length),low=\($s | map(select(. == "low")) | length)"' "$LEDGER"
else
  echo "critical=0,high=0,medium=0,low=0"
fi
```

Paste the printed line into the emit:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
  --tool ultra-audit \
  --verdict <GO|NO-GO|CONDITIONAL> \
  --counts <the printed counts>
```

`--counts` is required for a GO and always passed: all four keys, each a
plain number.

## Where each finding goes

**Fix now (counted)**: every finding that is not REFUTED and is attributable
to this change: on a line the diff touched, or on behavior the diff changed.
That includes tool evidence (red gate, failing tests), verified scan records,
verified spec gaps, verified challenger concerns, and any NEEDS-DECISION
finding until the user decides it. Ledger outcome `open`. Severity sets the
order fixes happen in, never whether they happen.

**Follow-up (listed, not counted)**: verified PRE-EXISTING findings,
repo-level gaps (no gate entrypoint, a scanner COVERAGE GAP), freshness
findings on dependencies the diff did not touch, in-range updates available
for dependencies the diff did touch (both for `/deps-update`), and bundled or
transitive advisories. Ledger outcome `follow-up`. These are not dropped:
right after this PR merges, the session fixes them in ONE follow-up PR,
reviewed by `/ultra-audit` at fast depth. A Follow-up item that is a
repo-level decision (adding a gate target, adopting a scanner) is marked ASK
and asked, never auto-fixed. The follow-up PR's own pre-existing findings are
listed for the user once and never become another follow-up PR.

**Closed (listed, not counted)**: REFUTED findings with their evidence,
`dismissal-upheld` entries with their evidence, and `accepted-by-user` entries.

## Verdict

- **GO**: every count is zero, Built is PASS, Spec is PASS or N/A, and
  `pr-stage.sh check` exited 0.
- **NO-GO**: any counted finding at any severity, Built FAIL, or Spec FAIL.
- **CONDITIONAL**: nothing is counted, but the run cannot vouch for the whole
  diff: the user scoped the review (`SCOPE_ASK`), the gate could not be
  launched (Built NOT RUN), or `pr-stage.sh check` found the real worktree
  changed during the review (list its paths). `receipt.sh verify` fails
  CONDITIONAL, so this needs a full, unscoped run before merge (for a changed
  tree: re-run on the current content).

`receipt.sh verify` fails a GO whose counts are nonzero, missing, or malformed.

## Fix rounds

A fix round is: fix everything counted, then re-run `/ultra-audit` on the
whole branch (staged, never `--last-commit`), with the ledger.

1. At most **2 autonomous fix rounds**. Repeated rounds past 2 mostly fix the
   previous round's fixes.
2. If the run after round 2 still counts findings, stop looping: present every
   counted finding to the user as one NEEDS-DECISION list (fix, redesign,
   split, or accept).
3. Apply the user's decisions: their fixes land, and an accept is recorded as
   `accepted-by-user` in the ledger.
4. One final run at **fast depth** (one finder, no challenger, no sweep)
   confirms and emits the receipt. Whatever it counts goes straight to the
   user as NEEDS-DECISION; there are no further autonomous rounds. Its
   receipt is NO-GO until the user's next decision and a fresh run make it GO.

Print the path on `Receipt:`. If `gh pr view --json number` works, also pass
`--pr <n>`. The merge gate runs `receipt.sh verify --pr <n> --require-tool
ultra-audit` (with chad-review 3.0.0+).
