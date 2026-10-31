# Node: verify

Adversarial verification of every finding raised by gate, tests, the
deterministic scans, skim, impl-review, spec-vs-diff, and challenger. This
replaces the old confidence-80 score filter. A confidence number is not
evidence: self-reported LLM confidence is poorly calibrated, and a threshold
dropped real bugs that no one had disproved. Findings now survive unless
someone proves them wrong.

Script-sourced findings (gate output, failing tests, `docs-drift`,
`contract-mirror`, `freshness` records) are already evidence. They skip
this node and go straight to the verdict.

## Verifiers

- `subagent_type: general-purpose`, `model: opus`, `effort: high`. This skill
  explicitly sets that effort on every verifier launch. Opus 5.5 defaults to
  `medium`, and a verifier is where the extra thinking pays.
- Never the agent that raised the finding. Never this conversation's
  rationale. A verifier gets the post-apply diff, the finding lines, the
  project's CLAUDE.md, and, on a re-run, the prior-run ledger (below).
- Group findings by file, up to 5 per verifier, every verifier launched in ONE
  message. With 5 or fewer findings in total, one verifier takes them all.

## The rule

Each finding gets exactly one ruling:

- **CONFIRMED**: the verifier reproduced it. That means a command it ran with
  quoted output (a failing test it wrote in a temp file, a script, a
  `go test -run`), or a quoted `file:line` that makes the failure certain.
- **PLAUSIBLE**: the failure scenario needs a realistic state the verifier
  could not construct here: a race, nil on a rare-but-reachable path, a zero
  value, an off-by-one, a retry storm, a lost regex anchor. **This is the
  default.** Not being able to confirm is not evidence of absence.
- **REFUTED**: only when the code proves it wrong, and the ruling must quote
  that proof. The cited code does not exist or says otherwise; the path is
  provably unreachable; an earlier line in this diff already guards it; or
  it is purely a style preference that no project rule names. "Speculative",
  "unlikely", and "probably fine" are not refutations.

For a behavioral claim, the verifier tries to run something before it reads:
a minimal repro, the scoped test, a one-off script. Executed evidence beats a
reading on both sides of the ruling. Verifiers never edit tracked files; temp
files go under `$TMPDIR` and are removed.

Verifiers may sharpen a `file:line` or adjust severity with a one-line reason.
They may also mark a finding `PRE-EXISTING` when the failing line is
untouched by the diff and the diff does not change whether it is reached.

## Output

Each verifier returns one line per finding:

`CONFIRMED|PLAUSIBLE|REFUTED | SEVERITY | file:line | finding | <evidence: quoted line or command + output>`

The parent prints `Verified: N raised, C confirmed, P plausible, R refuted`,
and lists each REFUTED finding with its quoted evidence. A refutation stays
visible, the same way the old dropped count did.

## Prior-run ledger

When ultra-audit re-runs on the same branch after fixes, the parent passes the
previous run's findings with their outcomes (fixed, or dismissed with
evidence) to the verifiers. A finding that the previous run dismissed with
quoted evidence and that matches the same code is REFUTED again by citing the
ledger. That keeps a fix loop from re-raising a settled question. A ledger
entry never refutes a finding about code changed since that run.
