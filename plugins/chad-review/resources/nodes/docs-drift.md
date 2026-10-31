# Node: docs-drift

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/docs-drift.sh"
```

Runs in the staged worktree (`pr-stage.sh`), plain; add `--last-commit` only
in the nothing-to-gate last-commit review. `CONTRA` and `STALE` rows are
findings and go to verify. `MARKER` and `INDEXED` are evidence, not
auto-findings. `OKDOC` means scanned-clean. Hand the records to the finder
that owns the docs (`resources/fanout.md`). `docs-apply` already ran in the
real worktree and computed its own records there.
