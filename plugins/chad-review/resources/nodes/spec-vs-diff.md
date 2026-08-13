# Node: spec-vs-diff

Fresh-context. Is this the right thing?

Only runs when pipeline printed `SPEC=yes`. Read `PLAN.md` or `plan.md` at the
repo root (and the PR body if a PR exists). Check:

- every requirement in the plan is implemented
- listed edge cases have tests
- nothing outside the plan's stated scope changed

Report gaps, not style. A flawless implementation of a contradictory plan is
still FAIL: state the contradiction and the resolution the diff chose.

This axis is independent of Built. FAIL here vetoes the `docs-apply` node.
No plan file after all: print Spec N/A and stop this node. Do not invent a spec.
