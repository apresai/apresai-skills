# codex-br: Run Codex on Amazon Bedrock

Run [OpenAI Codex](https://developers.openai.com/codex/cli/) from inside Claude
Code, but routed through **Amazon Bedrock** (`openai.gpt-5.6-sol`, provider
`amazon-bedrock`) instead of the ChatGPT/OpenAI backend.

`br` = **Bedrock**. The skill is the Bedrock twin of OpenAI's
[`codex` plugin](https://github.com/openai/codex-plugin-cc) (`/codex:review`,
`/codex:rescue`, ...). Those commands drive Codex through its app-server runtime,
which is structurally locked to your *default* Codex profile (ChatGPT). This skill
takes the one path that can select a different backend: a direct
`codex exec --profile br` call.

## What you get

When installed, the skill exposes three subcommands:

| Command | What it does |
|---|---|
| `/codex-br task <prompt>` | Delegate a coding / diagnosis / research task to Bedrock-backed Codex. Write-capable by default (`--read` for read-only). |
| `/codex-br review` | Built-in Codex reviewer over the current git diff (uncommitted by default; `--base <branch>`, `--commit <sha>`). |
| `/codex-br adversarial-review [focus]` | Steerable **challenge** review that questions the design, tradeoffs, and assumptions rather than just listing defects. |

All three default to **maximum reasoning effort (`ultra`)** and return Codex's
output verbatim. Pass `--effort <low|medium|high|xhigh|ultra>` to dial it down,
`--model <id>` to override the model.

**Cost:** every invocation bills `openai.gpt-5.6-sol` usage to your AWS account's
Bedrock spend, and `ultra` is the most expensive effort setting. `--effort medium`
is the economical choice for routine passes.

## Requirements

- **Node.js 18.18+** and the Codex CLI: `npm install -g @openai/codex`
- **An AWS account entitled to OpenAI frontier models on Bedrock.** `openai.gpt-5.6-sol`
  is a *gated* model (you may see "not available for this account, contact AWS
  Sales" until access is granted) and is currently served in **us-east-2 only**
  (`openai.gpt-5.4` adds us-west-2; us-east-2-only re-verified for `openai.gpt-5.6-sol` 2026-08-12). The open-weight `openai.gpt-oss-*` models are
  **not** served on this path, so they are not a substitute.
- **A Bedrock API key (bearer token)** from that account, exported as
  `AWS_BEARER_TOKEN_BEDROCK`.

## One-time setup

The skill itself is stateless: it just runs `codex --profile br exec ...`. The
setup below is what makes that profile resolve to Bedrock. Do it once.

### 1. Create the `br` Codex profile

A Codex profile is a file `~/.codex/<name>.config.toml`, layered on top of your
base config when you pass `--profile <name>`. Create `~/.codex/br.config.toml`:

```toml
model = "openai.gpt-5.6-sol"
model_provider = "amazon-bedrock"

[model_providers.amazon-bedrock.aws]
region = "us-east-2"
```

The built-in `amazon-bedrock` provider reads `AWS_BEARER_TOKEN_BEDROCK` (then the
normal AWS credential chain) and auto-strips the OpenAI-hosted tools
(`web_search`, `image_generation`) that Bedrock rejects, so it "just works." Your
default Codex config (no `--profile`) is untouched and stays on ChatGPT/OpenAI.
This is on-demand, not global.

### 2. Pin the token in `~/.codex/.env`

The Codex CLI reads `~/.codex/.env` **even in clean / headless shells**. This is
what lets the skill authenticate without you sourcing anything first. Set the
token there **without clobbering other keys the file may already hold** (a bare
`> ~/.codex/.env` would wipe them), and lock the file down:

```bash
mkdir -p ~/.codex && touch ~/.codex/.env
grep -v '^AWS_BEARER_TOKEN_BEDROCK=' ~/.codex/.env > ~/.codex/.env.tmp || true
printf 'AWS_BEARER_TOKEN_BEDROCK=%s\n' "$YOUR_BEDROCK_TOKEN" >> ~/.codex/.env.tmp
mv ~/.codex/.env.tmp ~/.codex/.env
chmod 600 ~/.codex/.env
```

Re-run this after the Bedrock token rotates: it replaces only the
`AWS_BEARER_TOKEN_BEDROCK` line and preserves everything else.

### 3. Add the `codex-br` shell alias (for interactive use)

The skill works without the alias (Codex loads `~/.codex/.env` natively; the
skill never sources the credential file into its shell), but the alias is the
convenient way to use the same backend yourself in a terminal. Add it to
`~/.zshrc` (or `~/.bashrc`):

```bash
# >>> codex-br bedrock profile >>>
alias codex-br='set -a; [ -f "$HOME/.codex/.env" ] && . "$HOME/.codex/.env"; set +a; codex --profile br'
# <<< codex-br bedrock profile <<<
```

The alias sources the token from `~/.codex/.env`, then activates `--profile br`.
Reload your shell so the alias is live (it is **not** active in an
already-running session):

```bash
source ~/.zshrc
```

> Juggling more than one AWS account / token? Keep each token under its own var
> (e.g. `PROD_BEDROCK_TOKEN`) and have the alias and `~/.codex/.env` set
> `AWS_BEARER_TOKEN_BEDROCK` from whichever one you want active. The skill only
> cares that `AWS_BEARER_TOKEN_BEDROCK` ends up populated.

### 4. Verify

```bash
# Confirm the token + account entitlement against the Bedrock mantle endpoint:
curl -s https://bedrock-mantle.us-east-2.api.aws/openai/v1/responses \
  -H "Authorization: Bearer $AWS_BEARER_TOKEN_BEDROCK" \
  -H "Content-Type: application/json" \
  -d '{"model":"openai.gpt-5.6-sol","input":"ping","max_output_tokens":16}'
# HTTP 200 + a response object = access confirmed.

# Confirm Codex routes through Bedrock:
source ~/.zshrc
codex-br exec --sandbox read-only "reply with exactly: bedrock ok"
# Headless / without the alias (this is the path the skill uses):
codex exec --profile br --sandbox read-only "reply with exactly: bedrock ok"
```

## Installation

Ships in the [apresai-skills](https://github.com/apresai/apresai-skills)
marketplace:

```
/plugin marketplace add apresai/apresai-skills
/plugin install codex-br@apresai-skills
```

Or symlink for local development:

```bash
git clone https://github.com/apresai/apresai-skills ~/dev/apresai-skills
ln -s ~/dev/apresai-skills/plugins/codex-br/skills/codex-br \
      ~/.claude/skills/codex-br
```

The marketplace install is the right default. A symlink serves whatever branch
the clone has checked out. Switch branches (or check out one where this plugin
doesn't exist) and the skill silently changes or dangles. Use it only while
actively developing the skill.

## Gotchas (learned the hard way)

- **`openai.gpt-5.6-sol` is invisible to `aws bedrock list-foundation-models`** (as
  of 2026-08, re-verified). The frontier GPT-5.x models live on a separate Bedrock "mantle" endpoint
  (`bedrock-mantle.us-east-2.api.aws`, OpenAI Responses API), not the standard
  runtime surface. Use the curl check above to confirm access, not
  `list-foundation-models` (which returns only the open-weight `gpt-oss-*`).
- **Reasoning effort `minimal` was rejected** by `openai.gpt-5.5` on Bedrock in 2026-06 (instant
  HTTP 400); assume the same for `openai.gpt-5.6-sol`. Valid values are
  `low | medium | high | xhigh | ultra` (`ultra` verified live on `openai.gpt-5.6-sol`
  2026-08-12). The skill defaults to `ultra`.
- **A `200` with `output_tokens: 0`** from the mantle endpoint is a transient
  server-side generation hiccup, not a config fault. Retry before escalating.
- **No background jobs.** This skill runs Codex non-interactively (`codex exec`),
  so there is no `/codex:status` / `/result` / `/cancel`. For that, use the
  ChatGPT-backed `codex:*` plugin. Background/job tracking lives in an app-server
  runtime that cannot select the `br` profile.
- **Feature loss on Bedrock vs the ChatGPT default:** no hosted web search or
  image generation. Local tooling and MCP servers (including an MCP-based web
  search like Brave) work normally and are provider-agnostic.

## How it relates to OpenAI's codex plugin

| | OpenAI `codex` plugin | `codex-br` (this) |
|---|---|---|
| Backend | Default profile → ChatGPT/OpenAI | `br` profile → Amazon Bedrock (`openai.gpt-5.6-sol`) |
| Transport | `codex app-server` (JSON-RPC, broker) | one-shot `codex exec` |
| Background jobs | Yes (`/status`, `/result`, `/cancel`) | No (foreground only) |
| Review | `/codex:review` + `/codex:adversarial-review` | `review` + `adversarial-review` |
| Auth | Codex login state | Bedrock bearer token in `~/.codex/.env` |

Use whichever backend you want for a given task. They coexist.
