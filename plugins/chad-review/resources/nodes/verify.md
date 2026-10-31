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
a reading on both sides. Read the code in the staged worktree (`DIR`), which
holds exactly the content under review. Put repro files under `$TMPDIR`,
outside `DIR` (a stray file in `DIR` makes `pr-stage.sh check` fail). When
a repro must live in the package (a Go test of an unexported symbol) or needs
the build environment (`node_modules`, `.env`), it runs in the real worktree:
create it, run it, delete it before returning, and confirm
`git status --porcelain` there is unchanged (`pr-stage.sh check` later
catches anything left behind). Never edit tracked files.

**PRE-EXISTING is a ruling, not a label.** A finder may suggest it; the
verifier confirms it only with evidence that the failing line is untouched by
the diff (quote the diff or `git blame`) AND that the diff does not change
whether it is reached. Unconfirmed, the finding is treated as the diff's.

Verifiers may sharpen a `file:line` or adjust severity, with a one-line reason.

## Output

One line per finding:

`CONFIRMED|PLAUSIBLE|REFUTED [PRE-EXISTING] | SEVERITY | file:line | finding | <evidence>`

**Reconcile before using the rulings.** The parent keeps the list of findings
it sent to each verifier and matches every returned line against it. A finding
with no ruling back (the verifier errored, timed out, or returned fewer lines)
is re-sent once, in a verifier batch of its own. Still no ruling: it is
PLAUSIBLE, with the evidence `no ruling returned`. No finding leaves verify
unplaced.

The parent prints one line covering every source and every batch (spec-vs-diff
and the sweep included):
`Verified: N ruled (S scan, F finder), C confirmed, P plausible, R refuted; T tool-evidence findings; U re-sent`
Each REFUTED finding is listed with its evidence. A refutation stays visible.

## Ledger

The ledger makes re-runs converge without letting anyone grade their own
work. It is persisted, so a fresh session (or the follow-up PR) sees it. Its
path comes from the REAL worktree and the `BRANCH=` line `pr-stage.sh stage`
printed, never from inside the staged worktree (that one is detached at the
merge base, so its branch reads `HEAD`):

```bash
REAL=<real worktree path>; BRANCH=<BRANCH= value>
dir="$(git -C "$REAL" rev-parse --path-format=absolute --git-common-dir)/ultra-audit/ledger"
mkdir -p "$dir" && echo "LEDGER=$dir/$(printf '%s' "$BRANCH" | tr '/' '-').jsonl"
```

Keep the printed `LEDGER=` path and paste it as a literal later.

One JSON object per line, per finding, per run:
`{"run": <n>, "head": "<HEAD= from pr-stage.sh>", "source": "impl-review|skim|tests|gate|spec|challenger|sweep|docs-drift|contract-mirror|freshness|repo|parent", "severity": "CRITICAL|HIGH|MEDIUM|LOW", "file": "...", "line": N, "finding": "...", "ruling": "CONFIRMED|PLAUSIBLE|REFUTED|TOOL", "pre_existing": true|false, "outcome": "open|fixed|dismissed|dismissal-upheld|refuted|accepted-by-user|follow-up", "evidence": "..."}`

- **Append-only.** Nothing is edited in place; a later line for the same
  finding (same `file`, `line`, and `finding`) supersedes earlier ones, and
  the newest line wins.
- After verify, the parent appends every placed finding of this run,
  whatever its source: tool evidence (a red gate or failing test, ruling
  `TOOL`), every ruled finding, and repo-level gaps such as no gate entrypoint
  or a COVERAGE GAP (ruling `TOOL` or the verifier's). Outcome by placement
  (`nodes/receipt.md`): Fix now is `open`; Follow-up is `follow-up`; REFUTED is
  `refuted`. As fixes land it appends a `fixed` line (same run number) rather
  than editing.
- **Carry-over.** On a re-run, every prior finding whose newest line is
  `open`, `fixed`, or `dismissed` goes to the re-check batch below, and every
  result of that batch is appended with THIS run's number. A still-open item
  therefore counts in this run even if no finder re-raises it.
- A finding re-raised this run that matches a still-valid `refuted`,
  `dismissal-upheld`, or `accepted-by-user` line is appended for this run with
  that same outcome (and its original evidence), so a user's accept is not
  counted again.
- The receipt counts come from this run's `open` entries (`nodes/receipt.md`),
  never from a hand-typed tally.
- `fixed` and `dismissed` are author claims, not rulings. On a re-run the
  parent hands every prior `fixed` and `dismissed` entry (and every prior
  entry still `open`) to a verifier batch of its own, which re-checks each one against the current code: does the fix
  hold, or does the dismissal's evidence still hold? A fix that holds stays
  `fixed`. A dismissal whose evidence holds becomes `dismissal-upheld`, which
  is Closed (listed with its evidence, not counted). A claim that does not
  hold becomes an `open` finding again (CONFIRMED or PLAUSIBLE). This is how a
  re-run proves the fix round, rather than trusting it.
- `refuted` records a verifier's REFUTED ruling with its evidence. A re-run
  re-raising it must defeat that evidence.
- `accepted-by-user` is recorded only when the user explicitly decided to
  leave the finding as is. It is listed, never counted.
- `follow-up` entries are the Follow-up list. They survive the merge in this
  branch's ledger file, which is where the follow-up PR reads its work from.
- A `refuted`, `dismissal-upheld`, or `accepted-by-user` entry about code
  changed since that run's `head` no longer applies; the finding is ruled
  fresh.
- `BRANCH=detached` shares one `detached.jsonl`; review a detached head only
  when no branch exists, and say so in the report.
