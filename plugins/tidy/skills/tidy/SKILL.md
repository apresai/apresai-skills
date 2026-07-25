---
name: tidy
description: Apply quality-only cleanups to the code just changed. Use when the user says "tidy this up", "clean this up", "simplify the code", "refactor what I just wrote", or invokes /tidy, and after finishing a feature or bug fix but BEFORE running /chad-review. Removes missed reuse, dead code, wrong-altitude logic, needless abstraction, defensive noise for impossible states, and compatibility scaffolding. Scope-fenced to the current diff, behavior-preserving, verified by the project's own tests. Never commits.
---

# Tidy

Applies the cleanups that `/chad-review`'s SIMPLIFY pass reports but never
performs. Quality only: this skill must not change what the code does.

## Where this sits in the cycle

```
build -> test -> /tidy (applies) -> /chad-review (gates, read-only) -> PR -> merge
```

**Run before the review, never after.** `/chad-review` is a merge gate, and its
verdict only holds while the diff against main is unchanged. Applying edits after
the gate puts unreviewed code on the path to main and re-arms the gate, costing a
second full review on every PR.

## Scope fence

Restate the boundary before editing anything: **the task is cleanup of the
current diff, and the fence is the files that diff touches.**

- Only files in the current diff. A file the change did not touch is out of
  bounds, however tempting.
- Never change behavior. Not the output, not the error surface, not the public
  signature, not the timing, not the log lines other tools parse.
- Never add a feature, a test, a dependency, or an abstraction.
- Never commit, never push, never touch git history.
- If a cleanup would change behavior, or needs a design decision, **do not apply
  it**. Report it under "Needs a decision" and move on.

## Steps

1. **Capture the target.** `git status --porcelain`. Uncommitted changes mean
   `git diff HEAD` plus each untracked file. A clean tree means the last commit:
   `git show HEAD`. Build the changed-files list. Nothing to work on means say so
   and stop.
2. **Record a baseline.** Run the tests covering the changed files, scoped, using
   the per-language commands in chad-review's
   `resources/pass-reference.md` § TESTS if that plugin is installed. Note which
   tests pass **before** any edit. A suite that is already red means stop and say
   so: you cannot prove behavior preservation against a broken baseline.
3. **Route by language.** If chad-review is installed, reuse its detector so both
   tools agree on what changed. Locate it rather than assuming a path: plugins
   install as `cache/<marketplace>/<plugin>/<version>/`, so there is no fixed
   sibling hop from this plugin's root.

   ```bash
   route=$(ls -d "$HOME"/.claude/plugins/cache/*/chad-review/*/resources/chad-review-route.sh \
                 "$HOME"/.claude/skills/chad-review/resources/chad-review-route.sh \
            2>/dev/null | sort -V | tail -1)
   [[ -n "$route" ]] && bash "$route"
   ```

   This is optional enrichment. If nothing is found, classify by extension
   yourself. Either way you need the per-language blocks for step 4.
4. **Apply the cleanups**, per §"What to clean". Small diff (at most 4 files, or
   a single language) means do it inline in the parent: delegation costs more
   than the work. Otherwise launch **one agent per language block**, each with
   the block's files, the scope fence verbatim, and an explicit `model`.
5. **Prove behavior is unchanged.** Re-run exactly the tests from step 2. Any
   test that passed before and fails now means **revert that cleanup**, do not
   debug it into place, and report it under "Reverted". Also re-run the project's
   type check or build when it is cheap (`tsc --noEmit`, `go build ./...`,
   `swift build`).
6. **Report**, per §"Output".

## What to clean

- **Missed reuse**: a new helper duplicating one that already exists. Grep before
  accepting any new helper, and prefer the existing symbol.
- **Dead code**: added-then-unused code, refactor leftovers, branches that can no
  longer be reached, imports nothing uses.
- **Wrong altitude**: a handler doing storage-shaped work, a data layer making
  presentation decisions, business logic in a transport adapter.
- **Needless abstraction**: an interface or protocol with one implementation and
  no test double, a wrapper that only forwards its arguments, generalization for
  a requirement that does not exist yet.
- **Defensive noise**: error handling, fallbacks, or validation for states that
  cannot occur. Trust internal code and framework guarantees; validate at system
  boundaries (user input, external APIs) only.
- **Compatibility scaffolding**: a feature flag or shim where the code could
  simply change.
- **Comment rot**: comments restating what the next line does, or narrating the
  change ("changed this to fix X"). Those address the reviewer, not the next
  reader, and become noise the moment the PR merges. Keep comments that state a
  constraint the code cannot show.

Leave alone: formatting the repo's formatter owns, naming that matches
surrounding convention, and anything the project's linter already enforces.

> chad-review's `resources/pass-reference.md` § SIMPLIFY carries the per-language
> signals (Go one-implementation interfaces and write-only struct fields,
> TypeScript redundant assertions and dead barrel re-exports, Swift and Python
> equivalents). Paste the matching sections into each agent prompt.

## Model policy

**Pass an explicit `model` on every Agent launch.** An omitted model silently
inherits the session tier, so a premium session pays premium rates for mechanical
cleanup and a cheap session under-powers it.

Use **`sonnet`**. The work is bounded, scope-fenced, behavior-preserving, and
checked empirically by the tests in step 5, which is exactly the shape Sonnet
handles well. A `sonnet` session stays `sonnet`. Escalate to `opus` only when the
user asks for it by name. **Never `haiku`** and never `fable`: the first is below
the floor for code edits, the second costs roughly double Opus for no gain here.

`opus` and `sonnet` are aliases resolved at spawn time. Never hardcode a dated
model ID.

## Delegation cap

One agent per language block is the entire budget. Do not spawn an agent to
review, verify, or double-check another agent's edits: step 5 runs the tests, and
that is the verification. Do not spawn a second agent for work one can finish.
For a small single-language diff, spawn nothing.

## Output

Lead with the outcome, then the detail. No preamble, no restated diff, no
narration of the process.

```
## Tidy
<N> cleanups applied across <M> files. Tests: <baseline result> -> <after result>.

### Applied
- <file:line> | <=12-word description of the cleanup

### Needs a decision
- <file:line> | what it is, and why applying it would change behavior

### Reverted
- <file:line> | cleanup backed out because <test name> went red
```

Omit any section that is empty. If nothing needed cleaning, say
`Tidy: clean, nothing to simplify` and stop.

Close with the handoff, since this skill is the step before the gate:
`Next: /chad-review`.

## Rules

- NEVER change behavior. Behavior-preserving is the whole contract.
- NEVER commit, push, or rewrite history.
- NEVER edit a file outside the current diff.
- NEVER apply a cleanup you cannot verify with the tests from step 2. Report it
  instead.
- ALWAYS pass an explicit `model` on every Agent launch. Never haiku, never
  fable.
- ALWAYS revert rather than debug when a previously-green test goes red.
- Run before `/chad-review`, never after.
