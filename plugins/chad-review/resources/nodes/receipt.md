# Node: receipt

Every completed run emits one, whatever the outcome. `--counts` is required
for a GO and is always passed:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
  --tool ultra-audit \
  --verdict <GO|NO-GO|CONDITIONAL> \
  --counts critical=N,high=N,medium=N,low=N
```

Emit from the real branch worktree, not a `pr-stage.sh` worktree: the
fingerprint is the merge-base diff, so it matches either way, and the receipt
store belongs to the real repo.

## Where each finding goes

**Fix now (counted)**: every finding that is not REFUTED and is attributable
to this change: on a line the diff touched, or on behavior the diff changed.
That includes tool evidence (red gate, failing tests), verified scan records,
verified challenger concerns, and any NEEDS-DECISION finding until the user
decides it. Severity sets the order fixes happen in, never whether they happen.

**Follow-up (listed, not counted)**: confirmed PRE-EXISTING findings,
repo-level gaps (no gate entrypoint, a scanner COVERAGE GAP), freshness
findings on dependencies the diff did not touch (run `/deps-update`), bundled
or transitive advisories. These are not dropped: right after this PR merges,
the session fixes them in ONE follow-up PR, reviewed by `/ultra-audit` like
any other. Items that need a user decision are asked, not deferred.

**Closed (listed, not counted)**: REFUTED findings with their evidence, and
`accepted-by-user` ledger entries.

## Verdict

- **GO**: every count is zero, Built is PASS, and Spec is PASS or N/A.
- **NO-GO**: any counted finding at any severity, Built FAIL, or Spec FAIL.
- **CONDITIONAL**: nothing is counted, but the run cannot vouch for the whole
  diff: the user scoped the review (`SCOPE_ASK`), or the gate could not finish
  (Built NOT RUN). `receipt.sh verify` fails CONDITIONAL, so this needs a full,
  unscoped run before merge.

`receipt.sh verify` fails a GO whose counts are nonzero, missing, or malformed.

## Fix rounds

Fix everything counted, then re-run `/ultra-audit` on the whole branch
(`pr-stage.sh stage`, never `--last-commit`), with the ledger. At most **2
fix rounds**. If round 2's re-run still counts findings, stop looping: present
them to the user as one NEEDS-DECISION list (fix, redesign, split, or accept).
Repeated rounds past 2 mostly fix the previous round's fixes. The user's answer
goes into the ledger, then one final run emits the receipt.

Print the path on `Receipt:`. If `gh pr view --json number` works, also pass
`--pr <n>`. The merge gate runs `receipt.sh verify --pr <n> --require-tool
ultra-audit`.
