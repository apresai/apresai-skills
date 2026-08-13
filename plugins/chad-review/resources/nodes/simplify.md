# Node: simplify

Invoke the Claude Code built-in `/simplify` on the current diff.

Then re-run the same gate the `gate` node ran. If that gate is red, stop apply,
report the red output, and do not treat the tree as Built PASS.

This node is omitted from `NODES=` on leaf, deps, and exec-md-only diffs.
Do not invent a run when it is absent.
