---
name: ultra-audit
description: Full adversarial pre-commit audit and the default pre-merge review. Use when the user invokes /ultra-audit or wants the gate, tests, in-range dep updates, docs brought in line, an Opus implementation review, a fresh-context challenger, spec-vs-diff, per-finding adversarial verification, and a gap sweep in one pass, with every surviving finding fixed before merge. Its receipt satisfies receipt.sh verify at the merge gate, the same gate a /chad-review receipt passes.
---

# Ultra Audit

Full audit of the dirty working tree, or the last commit if the tree is clean.
There are no tiers: every diff, a one-line typo included, gets every review
node. A script lists the nodes; this file executes that list.

**Why no tiers and no score threshold (3.0.0).** Routing a diff to a lighter
tier, and dropping findings under confidence 80, were both ways a real defect
got skipped. Anthropic's own guidance for Claude Opus is that a reviewer told
to filter finds the bug and then declines to report it, and that self-reported
confidence is not a reliable filter. So finders now report everything, and a
separate Opus verifier drops a finding only when it can quote the code or the
command output that disproves it. Uncertain findings stay, and get fixed.

**The default pre-merge review.** The receipt this run emits satisfies
`receipt.sh verify` at the merge gate, the same as a `/chad-review` receipt.
A GO receipt must record zero open findings.

`resources/...` paths resolve against the skill root:
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.

## Models and effort

Every agent this command launches is `subagent_type: general-purpose`,
`model: opus`, `effort: high`. This skill explicitly asks for that effort on
every launch: Opus 5.5 defaults to `medium`, and this is the review that gates
a merge. Never haiku or sonnet here, never fable. The parent orchestrates in
whatever model the session runs.

## Pre-flight

1. `git status --porcelain`. Any uncommitted change means review the working
   tree. A clean tree means the last commit. No commits and a clean tree: say
   "Nothing to review" and STOP.
2. Run the graph. Working-tree review:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pipeline.sh"
   ```

   Last-commit: add `--last-commit`. `--full` is accepted and changes nothing.
3. Print one line:
   `Ultra Audit: <working tree|last commit>, RISK=<risk>, AGENTS=<n>+verifiers, REASON=<reason>`
4. `SCOPE_ASK=1` means the diff is past 50 files or 3000 production lines. Ask
   whether to scope to specific directories. Scoping narrows the files, never
   the nodes.
5. `UNTRACKED` greater than 0: run `untracked-guard.sh backup` before any other
   node (pipeline already listed `untracked-backup` in that case). A non-zero
   backup exit: stop.

## Execute the plan

Read the `NODES=` list left to right. For each name, Read
`resources/nodes/<name>.md` and do what it says. `SKIP=` only ever holds nodes
with no input (no changed plan, no code to simplify, no untracked files). Do
not spawn an agent to decide whether a node has work.

Order is load-bearing: gate and tests run on the user's tree, apply nodes
mutate, then review nodes see the post-apply diff.

| Node | What it is |
|---|---|
| `untracked-backup` | `untracked-guard.sh backup`. Path goes in the report header. |
| `gate` | Project validate/check/verify/ci. ~60s cap. See the node file. |
| `docs-drift` | `docs-drift.sh` (plus `--last-commit` in that mode). |
| `contract-mirror` | `contract-mirror.sh`. |
| `tests` | Scoped tests for changed files. Quote failures. Do not edit. |
| `freshness-audit` | `freshness.sh`. Do not update. |
| `spec-vs-diff` | Fresh-context plan vs diff. Only when `SPEC=yes`. |
| `freshness-update` | In-range `npm update` / `go get -u` taking the newest in-range releases, per `nodes/apply-deps.md`. |
| `simplify` | Built-in `/simplify`, then re-run the gate. |
| `docs-apply` | `docs-apply.sh`. Skip the whole node if spec-vs-diff returned FAIL. |
| `skim` | Parent-only secrets / lying commands / risky config. |
| `impl-review` | Opus reviewers, one per routing block, at least one. |
| `challenger` | Opus fresh-context attack on the change and for missed findings. |
| `verify` | Opus verifiers rule CONFIRMED / PLAUSIBLE / REFUTED on every finding. |
| `sweep` | One Opus gap-finder; its new findings go through verify. |
| `receipt` | `receipt.sh emit --tool ultra-audit`. GO only at zero open findings. |

## Apply then review

After `gate` and `tests`, run `spec-vs-diff` if listed, then apply nodes
(`freshness-update`, `simplify`, `docs-apply`), then re-run the same gate.
Red after apply: stop, report the red output, do not emit a Built PASS. Skip
`docs-apply` when spec-vs-diff returned FAIL.

Reviewer prompts get the post-apply diff, the script records, and a rubric
path. Not this conversation. Not the author's rationale. Resolve
`pass-reference.md` to an absolute path before handing it to an agent (see
`resources/fanout.md`).

## Verdict

```
## Ultra Audit
RISK:      <risk surfaces or none>
Spec:      PASS | FAIL | N/A
Built:     PASS | FAIL
Challenge: HOLDS | DOES NOT HOLD
Verified:  N raised, C confirmed, P plausible, R refuted
Apply:     <what ran, or skipped because spec failed>

### Fix these (open, counted)
SEVERITY | CONFIRMED|PLAUSIBLE | file:line | finding | <what would confirm it, for PLAUSIBLE>

### Not blocking
REFUTED (with evidence), PRE-EXISTING, repo-level, informational

Receipt: <path>
```

Open findings are ordered by severity, then CONFIRMED before PLAUSIBLE. No
blended GO. Spec N/A when `SPEC=no`.

## After the verdict: fix everything open

Every open finding is fixed in the same PR, at every severity, then
`/ultra-audit` re-runs with the prior-run ledger (`nodes/verify.md`). A
finding the author believes is wrong is dismissed only with a quoted
`file:line` or a command and its output, recorded in the next report, never
by skipping it. A finding needing its own design or a user decision is
surfaced as NEEDS-DECISION with a concrete proposal, and it blocks GO until
the user decides.

The receipt satisfies `receipt.sh verify` at the merge gate. When this branch
is heading for merge, run `receipt.sh verify --pr <n>` immediately before
`gh pr merge`.

## Rules

- Execute `NODES=`. Do not invent nodes. Do not skip a listed node.
- The review itself never edits the change under review, never commits, and
  never deploys, publishes, releases, migrates, or pushes. Fixing happens
  after the verdict, as ordinary work in the session.
- Never drop a finding for low confidence or low severity. Only an
  evidence-backed REFUTED removes one from the counts.
- `/simplify` is the cleanup apply. Skip it when it is not in `NODES=`.
- Do not apply docs or plans when spec-vs-diff failed.
- Do not apply docs-apply into `CLAUDE.md`, `*/SKILL.md`, `.claude/**`,
  `prompts/`, or a plugin's `commands/`, `agents/`, or `skills/`.
- After untracked-backup, run `untracked-guard.sh verify --restore` before
  the receipt, the same way chad-review does.
