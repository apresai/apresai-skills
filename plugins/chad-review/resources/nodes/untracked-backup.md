# Node: untracked-backup

Runs in the real worktree, first, when it has untracked files (the plan lists
this node from the real worktree's count, not the staged one's):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" backup
```

Print the backup path in the report header. Non-zero exit: stop.

After `pr-stage.sh remove` and before the receipt, in the same real worktree,
against the backup this run just took:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" verify --restore
```

When this node did not run (no untracked files), skip the verify too: an
older backup from an earlier review would restore files the user has since
deleted on purpose.
