# Node: docs-apply

If spec-vs-diff ran and returned FAIL, skip this node entirely. Print
`Apply: docs skipped because spec failed`.

Otherwise:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/docs-apply.sh"
```

It applies only `STALE` live-value records from `docs-drift.sh` (a version
floor behind the authority file). `CONTRA` records are printed, not rewritten.

Never run it against `CLAUDE.md`, `*/SKILL.md`, `.claude/**`, `prompts/`, or a
plugin's `commands/`, `agents/`, or `skills/` directory. If those paths appear
in the STALE list, leave them and say so.
