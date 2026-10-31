---
name: ultra-audit
description: Adversarial pre-merge review and the merge gate. Use when the user invokes /ultra-audit or wants a change reviewed before merge. Reviews the whole PR branch, runs the project's gate and tests, Opus finders that report everything, and Opus verifiers that refute a finding only with quoted proof (code, command output, or the change's stated intent) or as a style preference no rule names; fast for small changes, deep (challenger plus gap sweep) for risky, large, prompt, or status-bearing-doc changes. Every surviving finding on the change is fixed; pre-existing ones become one follow-up PR. Its receipt is what the merge gate checks.
---

# Ultra Audit

Pre-merge review of a change: the whole PR branch plus any uncommitted work.

**Two depths, one rule.** Depth decides how many agents look. It never decides
which findings are kept. A small change gets one strong finder and is fast; a
risky or large one also gets a challenger and a gap sweep. At both depths,
finders report everything, Opus verifiers refute a finding only on quoted
proof (`nodes/verify.md` § The rule), and every surviving finding on the
change is fixed. (3.0.0 removed the old tiers and the confidence-80 filter,
which were how real findings got skipped.)

**Cost.** Deep depth is expensive: its first full run, on a 600-line prompt
and shell diff, took 50 Opus agents, about 4.1M subagent tokens, and 26
minutes (2026-10-31). Fast depth launches one finder plus verifiers. Every
deep trigger is a reason the extra cost buys something; do not force deep
with `--full` by habit.

**Dependencies are not updated here.** Review audits them. `/deps-update`
brings a repo to the newest releases within each current major as its own PR.

**Not read-only.** The gate, tests, and scanner write to disk, and the two
apply nodes edit the branch on purpose: `simplify` (built-in `/simplify`, code
files only) and `docs-apply` (stale live values in docs only). Those edits stay
uncommitted in the real worktree for the author to review and commit.

`resources/...` paths resolve against the skill root:
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.
Shell state does not survive between Bash calls, so `REAL`, `DIR`, `BRANCH`,
`HEAD`, `MERGE_BASE`, the ledger path, and the run number are values the
parent keeps and pastes into each command as literals (as `pr-stage.sh`
printed them), never shell variables it expects to still be set.

## Models and effort

Every agent this command launches is `subagent_type: general-purpose` and
`model: opus`, with effort set explicitly as each node file says (this skill
asks for it): finders `medium` at fast depth and `high` at deep depth;
verifiers, challenger, sweep, and spec-vs-diff always `high`. Never haiku,
sonnet, or fable. The built-in `/simplify` chooses its own models.

## Two trees

- **The real worktree** (`REAL`, `git rev-parse --show-toplevel` where the
  user invoked this) has `node_modules`, `.env`, and build caches. Everything
  that executes the project or edits files runs here: untracked-backup, the
  gate, tests, `freshness.sh`, `simplify`, `docs-apply`, `untracked-guard.sh
  verify --restore`, and the receipt.
- **The staged worktree** (`DIR`, from `pr-stage.sh stage`) is a read lens:
  a throwaway worktree where the whole branch diff plus uncommitted work shows
  as working-tree changes. Only readers use it: `pipeline.sh`,
  `chad-review-route.sh`, `docs-drift.sh`, `contract-mirror.sh`, and the
  finder and verifier agents. Nothing is edited there, and nothing in it is
  exported back.

`pr-stage.sh stage` prints `DIR=`, `BASE=`, `MERGE_BASE=`, `HEAD=`,
`BRANCH=` (the real branch, or `detached`), `FILES=`, `IGNORED_FORCED=`, and
`SUBMODULES=`. Keep every value: `BRANCH` and `HEAD` key the ledger, never
values read inside `DIR` (it is detached at the merge base). Exit 1 means
nothing to stage; exit 2 means it could not run (stop and report it).
`IGNORED_FORCED` counts branch files under gitignored paths and
`SUBMODULES` counts submodule pointer changes; both lists go to stderr.
Ignored force-added files are in `DIR` (marked intent-to-add) but easy to
miss, and a submodule pointer change is not visible in `DIR` at all, so the
parent names each one to the finders explicitly and reads each submodule
change itself (old and new commit, and the log between them), raising
findings on it like any finder.

## Pre-flight

1. Resolve the base the way `receipt.sh` does: `origin/HEAD`'s target, else
   the first of `origin/main`, `origin/master`, `main`, `master` that exists.
   Then `git status --porcelain` and `git rev-list --count <base>..HEAD`.
2. **No commits ahead and a clean tree: nothing to gate.** Say "Nothing to
   gate: no commits ahead of <base> and a clean tree", emit no receipt
   (`receipt.sh` refuses an empty diff, and there is no PR to gate), and STOP.
   If the user asked for a review of the last commit anyway, run
   `pipeline.sh --last-commit` in place and execute that plan, with the
   receipt node skipped and the report saying why.
3. **Anything else** (commits ahead, uncommitted work, or both) is a staged
   review. Never review a branch with `--last-commit`: after a fix commit
   that reviews only the fix while the receipt covers the whole diff.
4. **Plan on a first stage.** The plan has to exist before the real-tree
   nodes run, and `pipeline.sh` reads only a staged tree:

   ```bash
   # in REAL
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pr-stage.sh" stage
   # in DIR (paste REAL's path)
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pipeline.sh" --staged <REAL> [--full]
   # in REAL, right away
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pr-stage.sh" remove <DIR>
   ```

   `pr-stage.sh stage` exit 1 (nothing to stage: the branch's net diff is
   empty) means say "Nothing to review", emit no receipt, and STOP. Exit 2:
   stop and report its error.

   Print one line:
   `Ultra Audit: <BRANCH> vs <BASE>, MODE=<fast|deep>, RISK=<risk>, AGENTS=<n>+verifiers, REASON=<reason>`
5. `SCOPE_ASK=1`: the diff is past 50 files or 3000 production lines. Ask
   whether to scope the review to named directories. A scoped run still runs
   every script whole, but the finders, challenger, and sweep get only the
   hunks under those directories, and the run is CONDITIONAL
   (`nodes/receipt.md`): it cannot vouch for the rest.
6. **Ledger** (`nodes/verify.md` § Ledger): its path comes from `REAL` and
   `BRANCH`. `mkdir -p` its directory. This run's number is one more than the
   highest `run` in it (1 when it is missing or empty). A run number above 1
   makes this a re-run.

## Execute, in this order

The order is load-bearing. Each step names where it runs. Read each node file
(`resources/nodes/<name>.md`) when its step comes up, and run only the nodes
the plan lists in `NODES=`; `SKIP=` holds nodes that do not apply or have no
input. Do not spawn an agent to decide whether a node has work.

**Real worktree, on the change as written** (cwd `REAL`):

1. `untracked-backup`: `untracked-guard.sh backup`, when the plan lists it
   (it counts untracked files in `REAL`). Path goes in the report header.
2. `gate`: discover it, read its recipe, and run it to completion in the
   foreground. Nothing later starts until it has finished.
3. `tests`: scoped tests for the changed files. Quote failures.
4. `freshness-audit`: `freshness.sh`, audit only.
5. `spec-vs-diff`, only when `SPEC=yes`: one Opus agent, then its gaps get
   their own verifier batch at once, so Spec is settled before the apply
   nodes.

**Real worktree, the apply nodes** (cwd `REAL`):

6. `simplify`, when listed: built-in `/simplify` on code files only.
7. `docs-apply`, unless Spec is FAIL: `docs-apply.sh` given the branch's
   changed markdown, stale live values only (`nodes/docs-apply.md` has the
   exact command).
8. If either apply node changed a file, re-run the same gate, to completion.
   Red is a counted Built finding (tool evidence).

**Staged worktree, the review lens** (stage AFTER apply, so the lens holds the
post-apply content):

9. `pr-stage.sh stage` in `REAL` again, then `pipeline.sh --staged <REAL>`
   in the new `DIR` (both in the full path form above). This second plan's `MODE` and `NODES` govern steps 10 to
   12 (an apply edit can change depth). The real-tree nodes it lists already
   ran in steps 1 to 8 and do not run again.
10. In `DIR`: `docs-drift`, `contract-mirror`, then `skim` (parent), then
    `impl-review` and, when listed, `challenger`. Finders and verifiers get
    the post-apply diff from `DIR` (`git -C "$DIR" diff` plus its untracked
    files), plus the parent's findings on `IGNORED_FORCED` and `SUBMODULES`
    items.
11. `verify` on every finding from every source, with the reconciliation in
    `nodes/verify.md` (a finding sent without a ruling back is re-sent once,
    then PLAUSIBLE). Then `sweep` when listed, and its findings through one
    more verify batch.
12. `pr-stage.sh check <DIR>` in `REAL`. Exit 0: the real tree
    still holds exactly what was reviewed. Exit 1: it changed during the
    review; the paths it prints go in the report and the verdict is
    CONDITIONAL (`nodes/receipt.md`). Exit 2: same as 1, with its error.

**Real worktree, close out** (cwd `REAL`):

13. `pr-stage.sh remove <DIR>`.
14. When step 1 ran: `untracked-guard.sh verify --restore`, against the backup
    step 1 just took in this same tree. When step 1 was skipped, skip this too.
15. Write every placed finding to the ledger, compute the counts from it, and
    emit the receipt (`nodes/receipt.md`).

Reviewer prompts get the post-apply diff, the script records, and a rubric
path. Not this conversation. Not the author's rationale. Resolve
`pass-reference.md` to an absolute path before handing it to an agent (see
`resources/fanout.md`).

| Node | What it is |
|---|---|
| `untracked-backup` | `untracked-guard.sh backup` in `REAL`. |
| `gate` | Project validate/check/verify/ci, recipe read first, run to completion. |
| `tests` | Scoped tests for changed files, in `REAL`. |
| `freshness-audit` | `freshness.sh` in `REAL`, audit only. |
| `spec-vs-diff` | Opus plan vs diff, plus its own verifier batch. Only when `SPEC=yes`. |
| `simplify` | Built-in `/simplify` on code files only, in `REAL`. |
| `docs-apply` | `docs-apply.sh` in `REAL`, stale live values only. Skipped if Spec is FAIL. |
| `docs-drift` | `docs-drift.sh` in `DIR`. |
| `contract-mirror` | `contract-mirror.sh` in `DIR`. |
| `skim` | Parent-only secrets / lying commands / risky config. |
| `impl-review` | Opus finders: one (fast) or one per routing block (deep). |
| `challenger` | Deep only. Opus attack on the change itself. |
| `verify` | Opus verifiers rule CONFIRMED / PLAUSIBLE / REFUTED on every finding. |
| `sweep` | Deep only, first run of a branch only. One Opus gap-finder. |
| `receipt` | `receipt.sh emit --tool ultra-audit` in `REAL`, counts from the ledger. |

## Report

```
## Ultra Audit
MODE:      fast | deep (<reason>)
Spec:      PASS | FAIL | N/A
Built:     PASS | FAIL | NOT RUN
Challenge: HOLDS | DOES NOT HOLD | SKIPPED (fast)
Verified:  <the verify node's line>
Apply:     <what ran, and the files it changed>
Tree:      unchanged since staging | CHANGED: <paths from pr-stage.sh check>

### Fix now (counted)
SEVERITY | CONFIRMED|PLAUSIBLE|TOOL | file:line | finding | <evidence, or what would confirm it>

### Follow-up (after merge, one PR)
<verified pre-existing, repo-level gaps, untouched deps and in-range updates (/deps-update), with the item each needs; repo-level decisions marked ASK>

### Closed
<REFUTED with evidence; dismissal-upheld with evidence; accepted-by-user>

Verdict: GO | NO-GO | CONDITIONAL
Receipt: <path>
```

Fix-now findings are ordered by severity, then CONFIRMED before PLAUSIBLE.

## After the report

1. **Fix every Fix-now finding** in this PR, at every severity. A finding the
   author believes is wrong is recorded in the ledger as `dismissed` with its
   evidence; the next run's verifier re-checks it (`dismissal-upheld` closes
   it, otherwise it counts again). Never skip one silently.
2. **Re-run** `/ultra-audit` on the whole branch. At most **2 autonomous fix
   rounds**. If the run after round 2 still counts findings, stop: present
   every counted finding to the user as one NEEDS-DECISION list (fix,
   redesign, split, or accept). Apply the user's decisions (fixes, or
   `accepted-by-user` in the ledger), then one final run at **fast depth**
   confirms. Anything that final run counts goes straight to the user; there
   are no further autonomous rounds (`nodes/receipt.md` § Fix rounds).
3. **Merge on GO.** The merge gate runs
   `receipt.sh verify --pr <n> --require-tool ultra-audit` immediately before
   `gh pr merge` (with chad-review 3.0.0+).
4. **Follow-up PR.** Right after the merge, fix the Follow-up list in one
   branch cut fresh from `origin/main`. Items marked ASK (repo-level
   decisions, such as adding a gate target) are asked, not auto-fixed.
   Dependency items go to `/deps-update` instead. Review that PR with
   `/ultra-audit` at **fast depth**; its own pre-existing findings are listed
   for the user once and never chained into another follow-up PR. Its
   Fix-now findings are fixed in it like any change.

## Rules

- Execute the steps above in order, and the nodes the plan lists. Do not
  invent nodes. Do not skip a listed node, with exactly three exceptions:
  the receipt in the nothing-to-gate case; the sweep on a re-run (the
  ledger already holds an earlier run for this branch: a second sweep
  roughly doubles false positives, `nodes/sweep.md`); and the two fast-depth
  runs (the post-decision confirmation and the follow-up PR review), which run
  one finder at `medium` and skip challenger and sweep whatever `MODE` says,
  status-bearing docs included. In a fast-depth run the one finder reads each
  flagged status-bearing doc in full.
- The gate, tests, and apply nodes run in `REAL`; the scans, finders, and
  verifiers read `DIR`. Never edit `DIR`; never export from it.
- The finders and verifiers never edit the change. Only the apply nodes
  (`simplify`, `docs-apply`) change files during the review, and only as
  their node files say; fixing findings happens after the report.
- Never commit, deploy, publish, release, migrate, or push from inside the
  review, and never run a gate target that does (`nodes/gate.md`).
- Never drop a finding for low confidence or low severity. Only an
  evidence-backed REFUTED, an upheld dismissal, or the user's explicit
  decision closes one.
