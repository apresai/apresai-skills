---
name: ultra-audit
description: Routed pre-commit audit. Use when the user invokes /ultra-audit, wants a complexity-routed review (leaf, deps, small, standard, audit), or asks for spec-vs-diff, a fresh-context challenger, in-range dep updates, and docs brought in line with the implementation in one pass. Experimental. Does not replace /chad-review. Merge still requires a chad-review receipt.
---

# Ultra Audit

Routed audit of the dirty working tree, or the last commit if the tree is clean.
A script picks the pipeline. This file executes that plan. It does not re-derive
the tier.

**Experimental.** Does not replace `/chad-review`. Wrapup and `receipt.sh verify`
still require a chad-review receipt. After this command finishes, say
`Next: /chad-review` when the user is about to merge.

`resources/...` paths resolve against the skill root:
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.

## Pre-flight

1. `git status --porcelain`. Any uncommitted change means review the working
   tree. A clean tree means the last commit. No commits and a clean tree: say
   "Nothing to review" and STOP.
2. Run the graph. Working-tree review:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pipeline.sh"
   ```

   Last-commit: add `--last-commit`. `/ultra-audit --full` adds `--full`.
3. Print one line:
   `Ultra Audit: <working tree|last commit>, TIER=<tier>, AGENTS=<n>, REASON=<reason>`
4. `SCOPE_ASK=1` means the diff is past 50 files or 3000 production lines. Ask
   whether to scope to specific directories. If they proceed, keep `TIER=audit`.
5. `UNTRACKED` greater than 0: run `untracked-guard.sh backup` before any other
   node (pipeline already listed `untracked-backup` in that case). A non-zero
   backup exit: stop.

## Execute the plan

Read the `NODES=` list left to right. For each name, Read
`resources/nodes/<name>.md` **only if that name is listed**, then do what it
says. Do not Read a node file that is in `SKIP=`. Do not spawn an agent to
decide whether a node has work.

Order is load-bearing: gate and tests run on the user's tree, apply nodes
mutate, then review nodes see the post-apply diff.

| Node | What it is |
|---|---|
| `gate` | Project validate/check/verify/ci. ~60s cap. See the node file. |
| `untracked-backup` | `untracked-guard.sh backup`. Path goes in the report header. |
| `docs-drift` | `docs-drift.sh` (plus `--last-commit` in that mode). |
| `contract-mirror` | `contract-mirror.sh`. |
| `tests` | Scoped tests for changed files. Quote failures. Do not edit. |
| `freshness-audit` | `freshness.sh`. Do not update. |
| `freshness-update` | In-range `npm update` / `go get -u` per `nodes/apply-deps.md`. |
| `simplify` | Built-in `/simplify`, then re-run the gate. |
| `impl-review` | Fresh-context implementation review. |
| `spec-vs-diff` | Fresh-context plan vs diff. Only when `SPEC=yes`. |
| `challenger` | Fresh-context refute. Audit tier only. |
| `docs-apply` | `docs-apply.sh`. Skip the whole node if spec-vs-diff returned FAIL. |
| `skim` | Parent-only secrets / lying commands / doc accuracy. Leaf only. |
| `score` | Batched confidence filter, only if 5 or more findings were raised. |
| `receipt` | `receipt.sh emit --tool ultra-audit`. |

`APPLY=` is commentary for the report. The listed apply nodes are the source
of what actually runs.

## Apply then review

After `gate` and `tests`, run apply nodes (`simplify`, `freshness-update`,
`docs-apply`) if listed, then re-run the same gate. Red after apply: stop,
report the red output, do not emit a Built PASS.

Reviewer prompts get the post-apply diff, the script records, and a rubric
path. Not this conversation. Not the author's rationale. Resolve
`pass-reference.md` to an absolute path before handing it to an agent
(see `resources/fanout.md`). Always pass an explicit `model`. Session-relative
tiering is the table in `commands/chad-review.md` § Model tiering; Read that
section only when you are about to launch an agent.

## Verdict

```
## Ultra Audit
TIER:    <leaf|deps|small|standard|audit>
Spec:    PASS | FAIL | N/A
Built:   PASS | FAIL
Challenge: HOLDS | DOES NOT HOLD | SKIPPED
Apply:   <what ran, or skipped because spec failed>
Receipt: <path>
Next:    /chad-review
```

No blended GO. Spec N/A when `SPEC=no` or the node was skipped. Challenge
SKIPPED when `challenger` was not in `NODES=`.

Then `/chad-review` if this branch is heading for merge. An ultra-audit
receipt does not satisfy `receipt.sh verify`.

## Rules

- Execute `NODES=`. Do not invent nodes. Do not skip a listed node silently.
- Never commit. Never deploy, publish, release, migrate, or push.
- `/simplify` is the cleanup apply. Skip it when it is not in `NODES=`
  (leaf, deps, exec-md-only).
- Do not apply docs or plans when spec-vs-diff failed.
- Do not apply docs-apply into `CLAUDE.md`, `*/SKILL.md`, `.claude/**`,
  `prompts/`, or a plugin's `commands/`, `agents/`, or `skills/`.
- After untracked-backup, run `untracked-guard.sh verify --restore` before
  the receipt, the same way chad-review does.
- `--full` is the only override and it only goes up.
