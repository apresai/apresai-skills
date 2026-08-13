# Node: untracked-backup

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" backup
```

Print the backup path in the report header. Non-zero exit: stop.

Before the receipt node:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" verify --restore
```
