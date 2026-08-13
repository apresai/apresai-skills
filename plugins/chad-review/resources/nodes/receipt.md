# Node: receipt

Every completed run emits one, whatever the axes:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
  --tool ultra-audit \
  --verdict <GO|NO-GO|CONDITIONAL> \
  --counts critical=N,high=N,medium=N,low=N
```

Map axes to the receipt verdict: any Built FAIL or Challenge DOES NOT HOLD or
Spec FAIL is NO-GO. Spec N/A plus Built PASS plus Challenge SKIPPED or HOLDS
is GO. A pre-existing whole-project freshness CRITICAL the diff did not touch
is CONDITIONAL.

Print the path on `Receipt:`. If `gh pr view --json number` works, also pass
`--pr <n>`. The published comment is an ultra-audit receipt and does not
satisfy `receipt.sh verify`.
