# Node: receipt

Every completed run emits one, whatever the axes:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
  --tool ultra-audit \
  --verdict <GO|NO-GO|CONDITIONAL> \
  --counts critical=N,high=N,medium=N,low=N
```

Map to the receipt verdict: any Built FAIL, Spec FAIL, or Challenge DOES NOT
HOLD is NO-GO. Any surviving CRITICAL or HIGH finding from ANY node
(impl-review, skim, tests, docs-drift, contract-mirror, or freshness on a
diff-touched dependency) is also NO-GO: the axes summarize the run, they do
not outrank findings, and a receipt that satisfies the merge gate must never
carry a GO over an unfixed CRITICAL. A pre-existing whole-project freshness
CRITICAL the diff did not touch is CONDITIONAL. Otherwise GO. The
CRITICAL/HIGH half is also enforced mechanically: `receipt.sh verify` fails a
GO receipt whose own counts record critical or high findings.

Print the path on `Receipt:`. If `gh pr view --json number` works, also pass
`--pr <n>`. The published comment is an ultra-audit receipt and satisfies
`receipt.sh verify` at the merge gate, the same as a chad-review receipt.
