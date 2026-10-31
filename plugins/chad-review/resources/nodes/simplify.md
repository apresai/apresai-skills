# Node: simplify

Runs in the real worktree, after the gate has finished and before the review
lens is staged.

Invoke the Claude Code built-in `/simplify` on the code files in the diff only.
Never on executable prompt content (`CLAUDE.md`, `AGENTS.md`, any `SKILL.md`,
`.claude/`, `prompts/`, a plugin's `commands/`, `agents/`, `skills/`, or
`resources/*.md`); in a mixed diff, name the code files to it explicitly.
`/simplify` launches its own agents on its own models; that is the one
exception to ultra-audit's opus-only rule.

Its edits stay uncommitted in the real worktree. Print the files it changed on
the report's `Apply:` line. The gate re-run after the apply nodes
(`commands/ultra-audit.md` step 8) covers them; red is a counted Built
finding, and the tree is not Built PASS.

Omitted from `NODES=` when the diff has no production code (test files,
manifests, config, and docs do not count, so a test-only diff skips it), or
when routing failed (so prompt files cannot be told apart).
