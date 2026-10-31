# Node: docs-apply

If spec-vs-diff ran and returned FAIL, skip this node entirely. Print
`Apply: docs skipped because spec failed`.

Otherwise:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/docs-apply.sh"
```

It applies only `STALE` live-value records from `docs-drift.sh` (a version
floor behind the authority file). `CONTRA` records are printed, not rewritten.

It never rewrites executable prompt content: `CLAUDE.md`, `AGENTS.md`,
`*/SKILL.md`, `.claude/**`, `prompts/`, a plugin's `commands/`, `agents/`, or
`skills/`, or any `resources/*.md`. The script enforces that list; if those
paths appear in the STALE list, they stay as findings for a human fix. On a
staged PR review, carry its edits back with `pr-stage.sh export`.
