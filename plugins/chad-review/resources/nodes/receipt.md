# Node: receipt

Every completed run emits one, whatever the axes:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
  --tool ultra-audit \
  --verdict <GO|NO-GO|CONDITIONAL> \
  --counts critical=N,high=N,medium=N,low=N
```

## What counts

`--counts` holds every **open** finding attributable to this diff, at every
severity: CONFIRMED and PLAUSIBLE findings from verify (and script-sourced
findings) on a line the diff touched or on behavior the diff changed. A finding
needing a user decision (NEEDS-DECISION) counts until the user decides.

Not counted, but listed in the report under `Not blocking`:

- REFUTED findings (with their quoted evidence)
- `PRE-EXISTING` findings on untouched lines the diff does not reach
- repo-level gaps (no gate entrypoint), bundled or transitive freshness
  advisories, majors held back, and other informational lines

## Verdict

- **GO** only when every count is zero and Built, Spec, and Challenge all pass.
- **NO-GO** for any counted finding at any severity, Built FAIL, Spec FAIL, or
  Challenge DOES NOT HOLD. Severity decides the order fixes happen in, never
  whether they happen.
- **CONDITIONAL** when the only blocker is a whole-project freshness CRITICAL
  the diff did not touch, or a `COVERAGE ... GAP`.

`receipt.sh verify` enforces the GO half mechanically: it fails a GO receipt
whose counts are not all zero. The loop is fix, then re-run ultra-audit, until
a GO.

## Re-runs

On a re-run after fixes, pass the previous run's findings and their outcomes to
verify as the prior-run ledger (see `verify.md`). The author may dismiss a
finding only to the verifier's standard: a quoted `file:line` or a command with
its output, recorded in the report. The receipt is always emitted at full scope
for the new head and fingerprint.

Print the path on `Receipt:`. If `gh pr view --json number` works, also pass
`--pr <n>`. The published comment is an ultra-audit receipt and satisfies
`receipt.sh verify` at the merge gate, the same as a chad-review receipt.
