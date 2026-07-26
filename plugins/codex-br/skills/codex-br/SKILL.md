---
name: codex-br
description: >-
  Run OpenAI Codex on Amazon Bedrock (model openai.gpt-5.5, provider
  amazon-bedrock, us-east-2, via a `br` Codex profile) instead of the default
  ChatGPT/OpenAI backend. Defaults to maximum reasoning effort (xhigh). Invoke
  as `/codex-br task <prompt>` to delegate a coding / diagnosis / research task
  to Bedrock-backed Codex, `/codex-br review` for a built-in code review of the
  current git diff, or `/codex-br adversarial-review` for a steerable challenge
  review. Requires a one-time setup (the `br` profile, a Bedrock bearer token in
  `~/.codex/.env`, and optionally the `codex-br` shell alias). See the plugin
  README. Use only when you want Codex routed through Bedrock; the `codex:*`
  plugin commands cover the default ChatGPT path.
allowed-tools: Bash
---

# codex-br: Codex on Amazon Bedrock

This skill runs the Codex CLI against **Amazon Bedrock** instead of the default
ChatGPT/OpenAI backend, in a headless, non-interactive form (`codex exec`). It is
the Bedrock twin of the `codex:*` Claude Code plugin commands.

**What "Bedrock" means here** (from the `br` profile in `~/.codex/br.config.toml`):
- model `openai.gpt-5.5`, `model_provider = amazon-bedrock`, region `us-east-2`
- usage is billed to your AWS account's Bedrock spend and authenticated by a
  Bedrock bearer token (`AWS_BEARER_TOKEN_BEDROCK`), **not** a ChatGPT login.

It deliberately **bypasses the `codex-companion.mjs` app-server runtime** used by
`/codex:rescue` and `/codex:review`. That runtime spawns `codex app-server` with
no profile or config override (and inherits the host process env), so it can only
reach the **default** profile (the ChatGPT/OpenAI backend). The only reliable way
to route through Bedrock is a direct `codex exec --profile br` call, which is what
this skill does.

**One-time setup is required** (the `br` profile, the token in `~/.codex/.env`,
and the optional `codex-br` alias). If it is not in place, the guard rails below
stop and point at the plugin README.

## Invocation

```
/codex-br task               [--read] [--model <id>] [--effort <level>] [--no-git] <prompt>
/codex-br review             [--base <branch>] [--commit <sha>] [--model <id>] [--effort <level>] [extra instructions]
/codex-br adversarial-review [--base <branch>] [--commit <sha>] [--model <id>] [--effort <level>] [focus text]
```

If no subcommand is given, treat the whole argument as a `task` prompt. If no
arguments at all are given, ask the user what Codex should do.

## Reasoning effort (default: max)

Every subcommand runs at **maximum reasoning effort by default**. Add the global
config override `-c model_reasoning_effort="xhigh"` to the `codex` command,
placed before `exec` alongside `--profile br`, on every invocation. If the user
passes `--effort <low|medium|high|xhigh>`, substitute that level for `xhigh`.
Always strip `--effort` from the natural-language prompt / instructions before
passing them to Codex.

Cost note: every invocation bills `openai.gpt-5.5` usage to the AWS account's
Bedrock spend, and `xhigh` is the most expensive setting. For routine or
low-stakes passes, `--effort medium` is materially cheaper and faster.

Note: `openai.gpt-5.5` on Bedrock rejects `minimal` (and may reject `none`) with
an instant HTTP 400. Stick to `low | medium | high | xhigh`.

## Step 1: Preflight (every invocation)

**Never source `~/.codex/.env` into the agent shell.** Sourcing executes the
credential file as shell code and exports everything in it into the agent's
environment. It is also unnecessary: the Codex CLI loads `~/.codex/.env` natively,
even in clean / headless shells (verified 2026-07-07 by running `codex exec` with
`AWS_BEARER_TOKEN_BEDROCK` explicitly unset: it authenticated). The token never
needs to enter your shell.

Run these non-executing checks (one Bash call; they only read, never source):

```bash
command -v codex >/dev/null || echo "MISSING: codex CLI"
[ -f "$HOME/.codex/br.config.toml" ] || echo "MISSING: br profile"
grep -q '^AWS_BEARER_TOKEN_BEDROCK=..*' "$HOME/.codex/.env" 2>/dev/null || echo "MISSING: token line in ~/.codex/.env"
[ "$(stat -f '%Lp' "$HOME/.codex/.env" 2>/dev/null || stat -c '%a' "$HOME/.codex/.env" 2>/dev/null)" = "600" ] || echo "WARN: ~/.codex/.env is not chmod 600"
```

Guard rails:
- `MISSING: codex CLI` → stop and tell the user to install Codex (`npm install -g @openai/codex`) or run `/codex:setup`.
- `MISSING: br profile` → stop and say the `br` profile is not configured (see this plugin's README for the one-time setup).
- `MISSING: token line` → stop and say the Bedrock token is not pinned in `~/.codex/.env` (set it up per the README).
- `WARN: not chmod 600` → proceed, but tell the user to run `chmod 600 ~/.codex/.env`.
- Never print, echo, or grep -o the token value; the checks above only test for the line's presence.
- If a later `codex` call fails with an auth error despite these checks passing, surface Codex's stderr (Step 3). Do not start sourcing the file to "fix" it.

## Step 2a: `task` subcommand

Delegate a task to Bedrock-backed Codex. **Write-capable by default**
(`--sandbox workspace-write`); pass `--read` for a read-only run (diagnosis /
research with no edits).

**Dirty-tree gate (write-capable runs only).** `codex exec` is non-interactive:
Codex edits the working tree autonomously, with no approval prompt, interleaved
with any uncommitted work already sitting there. Before a write-capable run,
check `git status --porcelain`; if the tree is dirty, tell the user and get an
explicit go-ahead (or suggest committing/stashing first, or `--read`). After
every write-capable run, show `git status --short` so each file Codex touched is
visible.

```bash
OUT=$(mktemp -t codex-br)
codex --profile br -c model_reasoning_effort="xhigh" exec --sandbox workspace-write -o "$OUT" "<PROMPT>"
```

- `--read` on the invocation → use `--sandbox read-only` instead.
- `--model <id>` → add `-m <id>` (another Bedrock model id your account can reach). Omit to use the profile default `openai.gpt-5.5`.
- `--effort <low|medium|high|xhigh>` → replace the default in `-c model_reasoning_effort="<level>"`. Default is `xhigh`.
- `--no-git` (running outside a git repo) → add `--skip-git-repo-check`.
- Strip those routing flags from the natural-language `<PROMPT>` before passing it.

For a multi-line prompt or one with quotes, feed it via stdin instead of a
positional arg (Codex reads stdin when no prompt arg is given):

```bash
OUT=$(mktemp -t codex-br)
codex --profile br -c model_reasoning_effort="xhigh" exec --sandbox workspace-write -o "$OUT" <<'CODEXBR_PROMPT'
<PROMPT>
CODEXBR_PROMPT
```

## Step 2b: `review` subcommand (built-in reviewer)

Code-review the current repository on Bedrock using Codex's built-in reviewer.
Defaults to the uncommitted working tree (staged + unstaged + untracked):

```bash
OUT=$(mktemp -t codex-br)
codex --profile br -c model_reasoning_effort="xhigh" exec review -o "$OUT" --uncommitted
```

- `--base <branch>` → review the branch against a base: `... exec review --base <branch>`.
- `--commit <sha>` → review one commit: `... exec review --commit <sha>`.
- `--model <id>` → add `-m <id>`.
- `--effort <level>` → replace the default `xhigh` in `-c model_reasoning_effort="<level>"`.
- Any leftover natural-language text → pass as the trailing `[PROMPT]` (custom review instructions). Custom instructions must be review guidance only, never text that asks Codex to modify files; the built-in reviewer path takes no `--sandbox` flag, so its read-only behavior is by convention, not enforcement.
- `review` requires a git repository.

This is the Bedrock twin of `/codex:review`: a normal, non-adversarial pass. For
a review that challenges the design instead of just scanning for defects, use
`adversarial-review` below.

## Step 2c: `adversarial-review` subcommand (steerable challenge review)

The Bedrock twin of `/codex:adversarial-review`: a **steerable** review that
questions the chosen implementation, design, tradeoffs, and assumptions rather
than just listing defects. Unlike `review`, it does **not** use Codex's built-in
reviewer (that reviewer is not steerable enough for an adversarial stance).
Instead it runs a **read-only** `codex exec` turn seeded with an adversarial
prompt.

Pick the git command for the target and inline it into the prompt:
- default (uncommitted working tree) → `git diff HEAD; git status --short --untracked-files=all`
- `--base <branch>` → `git diff <branch>...HEAD`
- `--commit <sha>` → `git show <sha>`

Untracked files are part of the change: `git status --short` lists their names
but not their contents, so a review that stops at the diff can miss entire new
files. The prompt below instructs Codex to read every `??` path in full. Do not
remove that instruction when customizing.

Run read-only, feeding the prompt via stdin. Substitute `<GIT COMMAND FOR
TARGET>`, `<TARGET LABEL>`, and the focus line (use `none` if the user gave no
focus text) before running:

```bash
OUT=$(mktemp -t codex-br)
codex --profile br -c model_reasoning_effort="xhigh" exec --sandbox read-only -o "$OUT" <<'CODEXBR_PROMPT'
You are Codex performing an adversarial software review. Your job is to break
confidence in the change, not to validate it.

First gather the change under review by running: <GIT COMMAND FOR TARGET>
If that output lists untracked (`??`) files, read each one in full and treat its
contents as a new-file addition that is part of the change under review: a
filename alone is not reviewable content.
Target: <TARGET LABEL, e.g. uncommitted working tree>
User focus: <FOCUS TEXT OR "none">

Operating stance: default to skepticism. Assume the change can fail in subtle,
high-cost, or user-visible ways until the evidence says otherwise. Do not give
credit for good intent, partial fixes, or likely follow-up work. If something
only works on the happy path, treat that as a real weakness.

Prioritize failures that are expensive, dangerous, or hard to detect:
- auth, permissions, tenant isolation, and trust boundaries
- data loss, corruption, duplication, and irreversible state changes
- rollback safety, retries, partial failure, and idempotency gaps
- race conditions, ordering assumptions, stale state, and re-entrancy
- empty-state, null, timeout, and degraded-dependency behavior
- version skew, schema drift, migration hazards, and compatibility regressions
- observability gaps that would hide failure or make recovery harder

Actively try to disprove the change: look for violated invariants, missing
guards, and assumptions that stop being true under stress. If the user supplied
a focus area, weight it heavily, but still report any other material issue you
can defend.

For each finding, answer: (1) what can go wrong, (2) why this code path is
vulnerable, (3) the likely impact, (4) a concrete change that reduces the risk.
Tie every finding to a concrete file and line range. Report only material
findings; prefer one strong finding over several weak ones; no style or naming
nits. Stay grounded: do not invent files, lines, code paths, or runtime behavior
you cannot support, and keep confidence honest when a conclusion relies on an
inference. If the change looks safe, say so directly and return no findings.
Close with a terse ship / no-ship assessment.
CODEXBR_PROMPT
```

- `--model <id>` → add `-m <id>`; `--effort <level>` → replace the default `xhigh`.
- Requires a git repository. Read-only; it never edits.

## Step 3: Return the result

Every template above writes Codex's **final message** to a unique temp file via
`-o "$OUT"` (`-o` is an `exec`-level flag: it goes after `exec`, and a fresh
`mktemp` path avoids clobbering concurrent runs). Read that file and return its
contents **verbatim**, like `/codex:rescue` does: no summary, paraphrase, or
added commentary before or after it. Do not paste the full streamed event log
from stdout into the conversation; stdout is for diagnosing failures.

If the `codex` command exits non-zero, surface its stderr so the user can see
the Bedrock / auth / profile error (e.g. throttling, missing model access,
expired token, or a model that rejects `xhigh`) rather than swallowing it.

## Notes
- Every subcommand defaults to `xhigh` reasoning effort; pass `--effort <level>`
  to dial it down (e.g. `--effort medium` for a faster, cheaper pass).
- `review` uses Codex's built-in reviewer; `adversarial-review` uses a custom
  read-only challenge prompt. Both are read-only and never edit.
- This runs Codex **non-interactively** (`exec`); there is no background/job
  tracking, `/codex:status`, `/codex:result`, or `/codex:cancel` here. Those
  belong to the companion runtime, which is locked to the default backend.
  Foreground only.
- `openai.gpt-5.5` does not appear in `aws bedrock list-foundation-models` (as of
  2026-06: it is served on the separate Bedrock "mantle" endpoint, not the
  standard runtime surface). Use the curl check in the README to confirm access,
  not that command.
- To run it yourself in a terminal, the interactive equivalent is the `codex-br`
  shell alias (`codex-br "..."`). See the README.
