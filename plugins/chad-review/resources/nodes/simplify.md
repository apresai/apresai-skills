# Node: simplify

Invoke the Claude Code built-in `/simplify` on the code files in the diff only.
Never on executable prompt content (`CLAUDE.md`, `AGENTS.md`, any `SKILL.md`,
`.claude/`, `prompts/`, a plugin's `commands/`, `agents/`, `skills/`, or
`resources/*.md`); in a mixed diff, name the code files to it explicitly.
`/simplify` launches its own agents on its own models; that is the one
exception to ultra-audit's opus-only rule.

Then re-run the same gate the `gate` node ran. If that gate is red, stop
apply, report the red output, and do not treat the tree as Built PASS.

Omitted from `NODES=` when the diff has no code, or when routing failed (so
prompt files cannot be told apart). On a staged PR review (`pr-stage.sh`),
carry its edits back with `pr-stage.sh export`.
