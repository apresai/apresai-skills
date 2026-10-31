# Node: simplify

Invoke the Claude Code built-in `/simplify` on the current diff.

Then re-run the same gate the `gate` node ran. If that gate is red, stop apply,
report the red output, and do not treat the tree as Built PASS.

This node is omitted from `NODES=` when the diff has no code, or carries
executable prompt content (shipping excludes prompts from `/simplify`). Do not
invent a run when it is absent.
