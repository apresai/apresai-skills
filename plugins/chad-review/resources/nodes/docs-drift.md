# Node: docs-drift

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/docs-drift.sh"
```

Add `--last-commit` in that mode. `CONTRA` and `STALE` rows are findings.
`MARKER` and `INDEXED` are evidence, not auto-findings. `OKDOC` means
scanned-clean. Hold the records for `docs-apply`.
