# Node: impl-review

Fresh-context review of the post-apply diff. Is it built right?

Owns: drift (two things that should agree, don't), what changed, hostile
probes (auth, empty/nil, races, compat, injection), test coverage (do not run
tests; the tests node already did), observability, and accuracy of every
changed doc or comment.

Every reviewer is `subagent_type: general-purpose`, `model: opus`. This skill
explicitly sets effort: `medium` at fast depth (Opus 5.5 at medium matches
Opus 5 at high on coding evaluations), `high` at deep depth. Ignore the
`[REVIEW tier, sonnet]` hint routing prints; that is `/chad-review`'s tiering.

Every reviewer reads the staged worktree (`pr-stage.sh`), which holds the
post-apply content.

- **fast**: one reviewer over the whole diff, every file, prose included.
- **deep**: one reviewer per routing block from `chad-review-route.sh`, each
  scoped to its block's hunks, all in ONE message. `Docs / spec` blocks get
  their own reviewer too: no hunk goes unreviewed. When `RISK` is not `none`,
  name the risk surfaces so the reviewer probes them first.
- **Status-bearing docs** (route's `Docs / status-bearing` block) force deep
  depth. That block's reviewer gets the `docs-drift.sh` records and reads
  every flagged doc IN FULL, not just its hunks: a stale `Status: Active`
  line is rarely inside the diff. In a forced fast-depth run (the
  post-decision confirmation, the follow-up PR review) the one reviewer does
  the same for each flagged doc.

Prompt contract: `resources/fanout.md`. Rubric path: `pass-reference.md`,
sections DRIFT, BEHAVIOR AND RISK, TESTS (coverage), OBSERVABILITY. Do not
paste the rubric. Output contract from `fanout.md`, verbatim: report
everything, no filtering. No edit, no commit, no deploy.
