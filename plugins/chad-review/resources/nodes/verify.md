# Node: verify

Adversarial verification of every finding, from every source: impl-review,
skim, the tests node's judgments, spec-vs-diff, challenger, sweep, and the
heuristic scan records (`docs-drift`, `contract-mirror`, `freshness`). It
replaced the confidence-80 score filter in 3.0.0. Self-reported confidence is
not calibrated well enough to cut on, and that filter dropped real defects
nobody had disproved. Now a finding survives unless someone proves it wrong.

Only direct tool evidence skips verification: a red gate (compiler, linter,
typechecker output) and a failing test, each quoted. Everything else is ruled.

## Verifiers

- `subagent_type: general-purpose`, `model: opus`, `effort: high` on every
  launch. This skill explicitly asks for that model and effort; Opus 5.5
  defaults to `medium`, and the verifier decides what gets fixed.
- Never the agent that raised the finding, and never this conversation's
  rationale.
- Each verifier gets: the post-apply diff, its findings, the project's
  `CLAUDE.md` and the user's global `~/.claude/CLAUDE.md` (global rules are
  real rules), the rubric path `pass-reference.md` (resolved, as in
  `fanout.md`), and the ledger entries for its findings (below).
- Group findings by file, up to 5 per verifier, every verifier launched in ONE
  message. With 5 or fewer findings, one verifier takes them all.

## The rule

Each finding gets exactly one ruling:

- **CONFIRMED**: reproduced. A command run with quoted output (the scoped
  test, a temp script, a minimal repro), or a quoted `file:line` that makes
  the failure certain.
- **PLAUSIBLE**: the default. The failure needs a realistic state the verifier
  could not construct here (a race, nil on a rare-but-reachable path, a zero
  value, an off-by-one, a retry storm, a lost regex anchor). Not being able to
  confirm is not evidence of absence.
- **REFUTED**: only with quoted proof, one of:
  - the cited code does not exist, or says something else
  - the path is provably unreachable, or an earlier line already guards it
  - the cited rule does not exist in any CLAUDE.md or the rubric (quote the
    search), or says something else
  - the hit is inside a comment, string literal, test fixture, or generated
    file, and the finding depends on it being live code
  - the behavior is the stated intent of this change (quote the commit
    message, plan, or adjacent comment)
  - it is purely a style preference no rule names
  "Speculative", "unlikely", and "probably fine" are not refutations.

For a behavioral claim, run something before reading: executed evidence beats
a reading on both sides. Put repro files under `$TMPDIR`. When a repro must
live in the package (a Go test of an unexported symbol), create it, run it,
delete it before returning, and confirm `git status --porcelain` is unchanged.
Never edit tracked files.

**PRE-EXISTING is a ruling, not a label.** A finder may suggest it; the
verifier confirms it only with evidence that the failing line is untouched by
the diff (quote the diff or `git blame`) AND that the diff does not change
whether it is reached. Unconfirmed, the finding is treated as the diff's.

Verifiers may sharpen a `file:line` or adjust severity, with a one-line reason.

## Output

One line per finding:

`CONFIRMED|PLAUSIBLE|REFUTED [PRE-EXISTING] | SEVERITY | file:line | finding | <evidence>`

The parent prints one line covering every source and every batch, the sweep's
included:
`Verified: N ruled (S scan, F finder), C confirmed, P plausible, R refuted; T tool-evidence findings`
Each REFUTED finding is listed with its evidence. A refutation stays visible.

## Ledger

The ledger makes re-runs converge without letting anyone grade their own
work. It is persisted, so a fresh session sees it:
`$(git rev-parse --git-common-dir)/ultra-audit/ledger/<branch>.jsonl`, one
JSON object per finding per run:
`{"run": <n>, "head": "<sha>", "file": "...", "line": N, "finding": "...", "ruling": "...", "outcome": "fixed|dismissed|accepted-by-user|open", "evidence": "..."}`.

- The parent appends every ruled finding after verify, and updates outcomes
  as fixes land.
- `dismissed` is an author's claim that a finding is wrong, with evidence. It
  is not a ruling. The next run's verifier re-checks that evidence against
  the current code and rules REFUTED only if it still holds. Otherwise the
  finding is CONFIRMED or PLAUSIBLE again.
- `accepted-by-user` is recorded only when the user explicitly decided to
  leave the finding as is. It is listed, never counted.
- An entry about code changed since that run's head is ignored.
