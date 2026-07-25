---
name: tidy
description: Apply quality-only cleanups to the code just changed. This skill EDITS FILES, so use it only on an explicit request: the user says "tidy this up", "clean this up", "simplify what I just wrote", or invokes /tidy. Do not fire it on your own mid-task, and do not treat a passing mention of simplicity as a request to start editing. Removes missed reuse, dead code, wrong-altitude logic, needless abstraction, defensive noise for impossible states, and compatibility scaffolding. Scope-fenced to the current diff, behavior-preserving, and gated on a verifier that can actually disprove a change; applies nothing when the repo has none. Never edits executable prompt content, never commits. Runs BEFORE /chad-review.
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

### Never edit executable prompt content

`CLAUDE.md`, any `*/SKILL.md`, anything under `.claude/`, a `prompts/`
directory, and a plugin's `commands/`, `agents/`, or `skills/` directory are
**instructions a model executes**, not prose. They are out of bounds for every
cleanup in this skill.

The reason is the verifier. Every other cleanup here is safe because a test can
prove behavior did not change. Nothing can prove that for a file whose "behavior"
is how a model interprets it: deleting a seemingly redundant sentence can change
what the model does, and no suite will go red. What reads as comment rot in a
prompt is often the sentence carrying the constraint.

Report cleanups you would have made in those files under "Needs a decision" so a
human can judge them. Never apply them.

## Steps

1. **Capture the target.** `git status --porcelain`. Uncommitted changes mean
   `git diff HEAD` plus each untracked file. A clean tree means the last commit:
   `git show HEAD`. Build the changed-files list. Nothing to work on means say so
   and stop.
2. **Establish a verifier, and let it decide what you are allowed to do.** This
   step gates everything after it. Find the strongest check available for the
   changed files, in this order, and record its result **before** any edit:

   | Verifier available | What you may apply |
   |---|---|
   | Tests covering the changed files | Everything in §"What to clean" |
   | No tests, but a type check or build (`tsc --noEmit`, `go build ./...`, `swift build`, `cargo check`) | Only cleanups that compiler or type checker can disprove: dead code, unused imports, redundant type assertions, unreachable branches. **Not** altitude moves, abstraction removal, or anything that changes control flow |
   | Neither | Nothing. Apply no edits at all |

   With no verifier, "behavior-preserving" is unfalsifiable, so applying a
   cleanup would be a guess dressed as a guarantee. Report every finding under
   "Needs a decision", say plainly that the repo has no way to prove behavior
   was preserved, and stop. This is the common case in content and config repos,
   and it is a normal outcome, not a failure.

   An **already-red** baseline also stops the run: you cannot prove preservation
   against a broken starting point. Say which check was red and stop.

   Scoping commands per language live in chad-review's `pass-reference.md`
   § TESTS. Resolve its directory first with the snippet in step 3, which finds
   both files this skill borrows.
3. **Locate chad-review's resources, then route by language.** Resolve the
   directory rather than assuming a path: plugins install as
   `cache/<marketplace>/<plugin>/<version>/`, so there is no fixed sibling hop
   from this plugin's root.

   ```bash
   cr=$(ls -d "$HOME"/.claude/plugins/cache/*/chad-review/*/resources \
              "$HOME"/.claude/skills/chad-review/resources \
         2>/dev/null | sort -V | tail -1)
   # $cr/pass-reference.md  -> scoping commands (step 2) and SIMPLIFY signals
   # $cr/chad-review-route.sh -> language routing, so both tools agree
   [[ -n "$cr" ]] && bash "$cr/chad-review-route.sh"
   ```

   Both are optional enrichment. If `$cr` is empty, classify by extension
   yourself and use the language knowledge you have. Either way you need the
   per-language blocks for step 4.
4. **Apply the cleanups**, limited to what step 2's verifier can disprove, and
   skipping executable prompt content entirely. Small diff (at most 4 files, or
   a single language) means work inline in the parent: delegation costs more than
   the work. Otherwise launch **one agent per language block**, each with the
   block's files, the scope fence verbatim, the verifier tier from step 2, and an
   explicit `model`.
5. **Prove behavior is unchanged.** Re-run exactly the check from step 2. Green
   means done.

   Red means **revert, never debug**. Attribution matters here: if several
   language-block agents ran, the failing check does not say which block caused
   it. Revert one block at a time, most recently applied first, re-running the
   check after each, and stop as soon as it is green again. Report every reverted
   block under "Reverted" with the check that caught it. Do not attempt a partial
   revert inside a block; drop the block's cleanups as a unit and let a human
   re-apply them selectively.

   If the check is still red after every block is reverted, the working tree
   diverged from the baseline for some other reason. Say so plainly rather than
   continuing to revert.
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
<N> cleanups applied across <M> files. Verifier: <what ran>, <before> -> <after>.

### Applied
- <file:line> | <=12-word description of the cleanup

### Needs a decision
- <file:line> | what it is, and why it was not applied

### Reverted
- <language block> | cleanups dropped because <check> went red
```

Omit any section that is empty. If nothing needed cleaning, say
`Tidy: clean, nothing to simplify` and stop.

When step 2 found **no verifier**, apply nothing and lead with that:

```
## Tidy
No verifier available: no tests and no type check or build cover these files,
so behavior preservation cannot be proven. Applied nothing.

### Needs a decision
- <file:line> | the cleanup, and what would have to exist to make it provable
```

Close with the handoff, since this skill is the step before the gate:
`Next: /chad-review`.

## Rules

- NEVER change behavior. Behavior-preserving is the whole contract.
- NEVER commit, push, or rewrite history.
- NEVER edit a file outside the current diff.
- NEVER edit executable prompt content (`CLAUDE.md`, `*/SKILL.md`, `.claude/**`,
  `prompts/`, a plugin's `commands/`, `agents/`, or `skills/`). No verifier can
  prove a prompt still means the same thing.
- NEVER apply a cleanup step 2's verifier cannot disprove. With no verifier at
  all, apply nothing and say so.
- ALWAYS pass an explicit `model` on every Agent launch. Never haiku, never
  fable.
- ALWAYS revert rather than debug when a previously-green check goes red, one
  language block at a time until it is green again.
- Run before `/chad-review`, never after. If a review already ran, tidy, then
  re-run the review; the gate must see the final diff.
