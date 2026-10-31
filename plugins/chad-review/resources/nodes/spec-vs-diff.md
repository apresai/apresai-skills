# Node: spec-vs-diff

Fresh-context. Is this the right thing?

`subagent_type: general-purpose`, `model: opus`, `effort: high`.

Only runs when pipeline printed `SPEC=yes`. Read `PLAN.md` or `plan.md` at the
repo root (and the PR body if a PR exists). Check:

- every requirement in the plan is implemented
- listed edge cases have tests
- nothing outside the plan's stated scope changed

Report gaps, not style, in the `fanout.md` output contract. A flawless
implementation of a contradictory plan still has a gap: state the
contradiction and the resolution the diff chose.

**Settle Spec before the apply nodes.** The gaps go straight to a verifier
batch of their own (`nodes/verify.md`, reconciliation included), not to the
later verify node, because Spec decides whether `docs-apply` runs. Then:

- **FAIL**: at least one gap is CONFIRMED or PLAUSIBLE. Those gaps are counted
  findings, and FAIL vetoes the `docs-apply` node.
- **PASS**: no gaps, or every gap REFUTED.

The batch's rulings go in the ledger and in the report's `Verified:` line
like any other.

This axis is independent of Built. No plan file after all: print Spec N/A and
stop this node. Do not invent a spec.
