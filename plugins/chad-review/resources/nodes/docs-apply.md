# Node: docs-apply

Runs in the real worktree, after `simplify` and before the review lens is
staged.

If Spec is FAIL (a spec gap survived its verifier batch), skip this node
entirely. Print `Apply: docs skipped because spec failed`.

Otherwise:

```bash
# the branch's changed markdown, committed or not, from REAL:
docs=$( { git diff --name-only "$MERGE_BASE" -- '*.md' '*.mdx'; git ls-files --others --exclude-standard -- '*.md' '*.mdx'; } | sort -u )
[[ -n "$docs" ]] && bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/docs-apply.sh" -- $docs
```

`MERGE_BASE` is from the first `pr-stage.sh stage`. With no changed markdown,
the node has nothing to do.

It applies only `STALE` live-value records from `docs-drift.sh` (a version
floor behind the authority file). `CONTRA` records are printed, not rewritten.
Its edits stay uncommitted in the real worktree; print the files it changed on
the report's `Apply:` line.

It never rewrites executable prompt content: `CLAUDE.md`, `AGENTS.md`,
`*/SKILL.md`, `.claude/**`, `prompts/`, a plugin's `commands/`, `agents/`, or
`skills/`, or any `resources/*.md`. The script enforces that list; if those
paths appear in the STALE list, they stay as findings for a human fix.
