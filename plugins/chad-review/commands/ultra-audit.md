---
name: ultra-audit
description: Adversarial pre-merge review and the merge gate. Use when the user invokes /ultra-audit or wants a change reviewed before merge. Reviews the whole PR branch, runs the project's gate and tests, Opus finders that report everything, and Opus verifiers that drop a finding only on quoted evidence; fast for small changes, deep (challenger plus gap sweep) for risky or large ones. Every surviving finding on the change is fixed; everything else becomes one follow-up PR. Its receipt is what the merge gate checks.
---

# Ultra Audit

Pre-merge review of a change: the whole PR branch, or the dirty working tree,
or the last commit on a clean main.

**Two depths, one rule.** Depth decides how many agents look. It never decides
which findings are kept. A small change gets one strong finder and is fast; a
risky or large one also gets a challenger and a gap sweep. At both depths,
finders report everything, Opus verifiers drop a finding only when they can
quote code or command output that disproves it, and every surviving finding
on the change is fixed. (3.0.0 removed the old tiers and the confidence-80
filter, which were how real findings got skipped.)

**Cost.** Deep depth is expensive: its first full run, on a 600-line prompt
and shell diff, took 50 Opus agents, about 4.1M subagent tokens, and 26
minutes (2026-10-31). Fast depth launches one finder plus verifiers. Every
deep trigger is a reason the extra cost buys something; do not force deep
with `--full` by habit.

**Dependencies are not updated here.** Review audits them. `/deps-update`
brings a repo to the newest in-range releases as its own PR.

`resources/...` paths resolve against the skill root:
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.

## Models and effort

Every agent this command launches is `subagent_type: general-purpose` and
`model: opus`, with effort set explicitly as each node file says (this skill
asks for it): finders `medium` at fast depth and `high` at deep depth;
verifiers, challenger, sweep, and spec-vs-diff always `high`. Never haiku,
sonnet, or fable. The built-in `/simplify` chooses its own models.

## Pre-flight: pick the target

1. `git status --porcelain`, and the commits ahead of the base
   (`git rev-list --count origin/main..HEAD`, or `main` without a remote).
2. **Commits ahead of the base: review the whole branch.**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pr-stage.sh" stage
   ```

   It prints `DIR=`: a throwaway worktree where the full branch diff (plus any
   uncommitted work) shows as working-tree changes. Run every script node with
   that directory as the working directory. Never review a branch with
   `--last-commit`: after a fix commit that reviews only the fix while the
   receipt covers the whole diff. Remove the worktree with
   `pr-stage.sh remove <dir>` before the receipt.
3. No commits ahead and a dirty tree: review the working tree in place.
4. No commits ahead and a clean tree (on main): `--last-commit`. Nothing at
   all: say "Nothing to review" and STOP.
5. Run the plan:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pipeline.sh"
   ```

   (`--last-commit` only in case 4; `--full` forces deep.) Print one line:
   `Ultra Audit: <branch vs base|working tree|last commit>, MODE=<fast|deep>, RISK=<risk>, AGENTS=<n>+verifiers, REASON=<reason>`
6. `SCOPE_ASK=1`: the diff is past 50 files or 3000 production lines. Ask
   whether to scope to directories. A scoped run cannot emit GO (see
   `nodes/receipt.md`).
7. Load the ledger (`nodes/verify.md` § Ledger) for this branch, if any.

## Execute the plan

Read `NODES=` left to right. For each name, Read `resources/nodes/<name>.md`
and do what it says. `SKIP=` holds nodes that do not apply at this depth or
have no input. Do not spawn an agent to decide whether a node has work.

| Node | What it is |
|---|---|
| `untracked-backup` | `untracked-guard.sh backup`. Path goes in the report header. |
| `gate` | Project validate/check/verify/ci, run to completion. |
| `docs-drift` | `docs-drift.sh`. |
| `contract-mirror` | `contract-mirror.sh`. |
| `tests` | Scoped tests for changed files. Quote failures. |
| `freshness-audit` | `freshness.sh`, audit only. |
| `spec-vs-diff` | Opus plan vs diff. Only when `SPEC=yes`. |
| `simplify` | Built-in `/simplify` on code files only, then re-run the gate. |
| `docs-apply` | `docs-apply.sh`, stale live values only. Skipped if spec failed. |
| `skim` | Parent-only secrets / lying commands / risky config. |
| `impl-review` | Opus finders: one (fast) or one per routing block (deep). |
| `challenger` | Deep only. Opus attack on the change itself. |
| `verify` | Opus verifiers rule CONFIRMED / PLAUSIBLE / REFUTED on every finding. |
| `sweep` | Deep only. One Opus gap-finder; its findings go through verify. |
| `receipt` | `receipt.sh emit --tool ultra-audit`, counts always passed. |

Order is load-bearing: the gate and tests run on the change as written, spec
before the apply nodes, apply nodes (`simplify`, `docs-apply`) before the
finders, so finders see the post-apply diff, and verify after every finder.
Red gate after an apply: report it; it is a counted Built finding. On a staged
review, carry apply-node edits back to the real branch with
`pr-stage.sh export <dir> | git apply` before removing the staged worktree.

Reviewer prompts get the post-apply diff, the script records, and a rubric
path. Not this conversation. Not the author's rationale. Resolve
`pass-reference.md` to an absolute path before handing it to an agent (see
`resources/fanout.md`).

## Report

```
## Ultra Audit
MODE:      fast | deep (<reason>)
Spec:      PASS | FAIL | N/A
Built:     PASS | FAIL | NOT RUN
Challenge: HOLDS | DOES NOT HOLD | SKIPPED (fast)
Verified:  <the verify node's line>
Apply:     <what ran>

### Fix now (counted)
SEVERITY | CONFIRMED|PLAUSIBLE | file:line | finding | <evidence, or what would confirm it>

### Follow-up (after merge, one PR)
<pre-existing, repo-level, untouched deps (/deps-update), with the item each needs>

### Closed
<REFUTED with evidence; accepted-by-user>

Verdict: GO | NO-GO | CONDITIONAL
Receipt: <path>
```

Fix-now findings are ordered by severity, then CONFIRMED before PLAUSIBLE.

## After the report

1. **Fix every Fix-now finding** in this PR, at every severity. A finding the
   author believes is wrong is recorded in the ledger as `dismissed` with its
   evidence; the next run's verifier re-checks it. Never skip one silently.
2. **Re-run** `/ultra-audit` on the whole branch. At most 2 fix rounds; then
   whatever is still counted goes to the user as one NEEDS-DECISION list
   (`nodes/receipt.md` § Fix rounds).
3. **Merge on GO.** The merge gate runs
   `receipt.sh verify --pr <n> --require-tool ultra-audit` immediately before
   `gh pr merge`.
4. **Follow-up PR.** Right after the merge, fix the Follow-up list in one
   branch cut fresh from `origin/main`, reviewed by `/ultra-audit` like any
   change. Dependency items go to `/deps-update` instead.

## Rules

- Execute `NODES=`. Do not invent nodes. Do not skip a listed node.
- The finders and verifiers never edit the change. Only the apply nodes
  (`simplify`, `docs-apply`) change files during the review, and only as
  their node files say; fixing findings happens after the report.
- Never commit, deploy, publish, release, migrate, or push from inside the
  review.
- Never drop a finding for low confidence or low severity. Only an
  evidence-backed REFUTED, or the user's explicit decision, closes one.
- After untracked-backup, run `untracked-guard.sh verify --restore` before
  the receipt.
