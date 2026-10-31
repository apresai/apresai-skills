# apresai Skills Marketplace

Production-ready Claude Code skills, mined from real production projects.

## Installation

```
/plugin marketplace add apresai/apresai-skills
```

After Claude Code reloads, the skills below are available via slash commands.

## Plugins (8)

| Plugin | Slash commands | What it does |
|---|---|---|
| **[apple-release](./plugins/apple-release/)** | `/release` · `/release-testflight` · `/release-consistency` · `/release-xcodecloud` · `/app-store-audit` | iOS/macOS release automation to TestFlight + App Store Connect, plus a pre-submission audit against the **full saved App Store Review Guidelines** (1,832 lines, fetched from `developer.apple.com`). Audit detects empty usage descriptions, Privacy Manifest gaps, non-StoreKit payments in digital-content apps, web-view-only apps, ATS exceptions, and more. Every finding cites the exact guideline ID with verbatim rule text. |
| **[bubbletea-design](./plugins/bubbletea-design/)** | (skill auto-triggers) | Build beautiful Go TUIs with **Bubble Tea v2 / Bubbles v2 / Lip Gloss v2**. Architecture patterns, component catalog, styling recipes, async/streaming patterns, v1→v2 migration map, 33 gotchas, 13 patterns. Includes real-world recipes mined from production CLIs. |
| **[chad-review](./plugins/chad-review/)** | `/ultra-audit` · `/deps-update` · `/chad-review` | **`/ultra-audit` is the merge gate.** It reviews the whole PR branch plus uncommitted work: `pr-stage.sh` stages it as a read-only lens for the scans (`docs-drift.sh`, `contract-mirror.sh`) and the agents, while the project's own gate (its recipe read first, never a target that deploys or probes production), scoped tests, `freshness.sh`, and the apply steps run in your real worktree. Opus finders report every finding unfiltered; Opus verifiers rule CONFIRMED, PLAUSIBLE, or REFUTED, refuting only on quoted evidence (code, command output, or the change's stated intent) or a pure style preference no rule names, and a red gate or failing test counts without a ruling. No confidence threshold: uncertain findings stay and get fixed. Two depths change how many agents look, never what is kept: **fast** (one finder, effort medium) for small changes, **deep** (a finder per routing block, a fresh-context challenger, one gap sweep per branch, effort high) for high-risk paths, prompt content, status-bearing docs, or diffs past 15 files or 400 production lines. Findings on the change are fixed in the PR at every severity; pre-existing findings and repo-level gaps go to one follow-up PR after merge, reviewed at fast depth and never chained into another (repo-level decisions such as adding a gate target are asked, not auto-fixed). A persisted ledger lets re-runs converge and supplies the receipt's counts: at most 2 autonomous fix rounds, then everything still counted goes to you as one decision list, followed by one fast confirmation run. **Breaking in 3.0.0:** a GO receipt must record zero open findings, `emit --verdict GO` requires all four `--counts`, and with chad-review 3.0.0+ the merge gate (`receipt.sh verify --require-tool ultra-audit`) accepts only ultra-audit receipts emitted by 3.0.0 or later, so an open PR holding only a 2.x GO needs a re-review with 3.0.0. **`/deps-update`** brings a repo to the newest stable release within each current major (security fixes included, never a major unasked) as its own `deps:` PR: exact npm, pnpm, and yarn pins move with a pinned `npm-check-updates`, Go with `go get -u`, other ecosystems with their native in-range updater or are skipped and named; each manifest's update is kept only if the gate re-runs green, a reverted one becomes a decision item, and the blocked-packages check and osv-scanner run after. **`/chad-review`** remains the explicit 5-pass fan-out (drift, behavior and risk, tests, observability, freshness) with session-relative sonnet/opus reviewer tiering, the same evidence-required verifier, and the same zero-open-finding GO; with 3.0.0+ its receipt does not satisfy the merge gate. Unlike `/ultra-audit`, which only audits dependencies, its pass 5 updates them in place with the same procedure, kept only on a green gate and left uncommitted. Both are **not read-only**: they run your gate, tests, codegen, linters, and scanner, which write to disk; `/ultra-audit`'s apply steps edit your branch (built-in `/simplify` on code files, `docs-apply.sh` on stale live values in docs) and `/chad-review` rewrites manifests and lockfiles, all left uncommitted for you to review; and both back up untracked files first because the finders' no-edit rule is prompt-enforced. Every review emits a machine-readable receipt (verdict, head SHA, stable diff fingerprint) that fails closed on a changed diff, a failed verdict, nonzero or malformed counts, or a look-alike review. |
| **[codex-br](./plugins/codex-br/)** | `/codex-br task` · `/codex-br review` · `/codex-br adversarial-review` | Run **OpenAI Codex on Amazon Bedrock** (`openai.gpt-5.6-sol`, provider `amazon-bedrock`) instead of the ChatGPT backend, via a `br` Codex profile. Delegate tasks, run the built-in reviewer, or run a steerable adversarial challenge review, all at max reasoning effort (`ultra`), output returned verbatim. The Bedrock twin of OpenAI's `codex:*` plugin; includes one-time setup for the profile, the `~/.codex/.env` token pin, and the `codex-br` shell alias. |
| **[go-lambda](./plugins/go-lambda/)** | `/go-lambda-builder` | Go on AWS Lambda done right: `provided.al2023` + ARM64/Graviton2 + AWS SDK v2. Includes production patterns from 8+ real Lambda projects: bounded-timeout `LoadDefaultConfig`, STS session policies via `json.Marshal`, `TestSchemaDrift` reflection, ULID over UUID v4, OpenAPI-first via `oapi-codegen`, single-table DynamoDB with typed structs. |
| **[image-encoding](./plugins/image-encoding/)** | `/image-encoding` | Modern web image encoding with **AVIF** (primary, ~95% browser support) and **WebP** (fallback) via the `<picture>` cascade. Covers `cwebp` / `dwebp` / `avifenc` CLIs with current defaults, JPEG XL status, Next.js Image integration. |
| **[nextjs-opennext](./plugins/nextjs-opennext/)** | `/nextjs-deploy` | Next.js on AWS via **OpenNext v4 + CDK**. Includes production-mined patterns: `CachePolicyId` override (`4135ea2d-…`) required or CloudFront caches SSR forever, `WARM_PARAMS` env shape, Server-Components-only auth (no middleware / no Lambda@Edge), `__Secure-` vs `__Host-` cookie prefix behavior, cost-tag schema, NextAuth.js v5 RBAC, ISR DynamoDB GSI naming. |
| **[xai-voice](./plugins/xai-voice/)** | (skill auto-triggers) | Master reference for **xAI's three voice APIs**: Grok **Text-to-Speech** (`POST /v1/tts`), **Speech-to-Text** (`/v1/stt`), and the realtime **Speech-to-Speech** voice agent (`wss://api.x.ai/v1/realtime`). Contracts verified by live probe against `api.x.ai`, because the docs are behind the API: **26 voices live where docs say 5**, two undocumented codecs, a documented request field that doesn't exist, and **no `model` field at all** on `/v1/tts`. Covers the trap that ships broken audio (unrecognized bracket speech tags are *read aloud*, so `[laugh]` laughs but `[laughs]` says "laughs"), plus a production Go client (there is no xAI Go SDK, and the audio surface is **not** OpenAI-compatible), retry/concurrency tuning, SIP telephony, and a zero-cost schema-discovery technique that works on any `serde`-backed API. |

## Versioning

The marketplace itself follows semver, tracked in the top-level `version` field of `.claude-plugin/marketplace.json` and in git tags. Individual plugins evolve at their own pace, so a plugin's version lives in two places that must agree: `plugins/<name>/.claude-plugin/plugin.json` and that plugin's entry in `marketplace.json`. Bump a plugin by editing both as part of the change that earned it; the `make bump-*` targets move the marketplace version only and leave per-plugin versions alone.

## How it's built

This is a Claude Code marketplace, not a software project. Each plugin lives under `plugins/<name>/` with:

```
plugins/<name>/
├── .claude-plugin/plugin.json   # plugin manifest
├── README.md                     # human-facing overview
├── commands/<name>.md            # slash command(s) + skill content
├── skills/<name>/                # multi-file skill (e.g. bubbletea-design, codex-br)
└── resources/                    # static assets (apple-release ships the
                                  # full App Store Review Guidelines here)
```

The `Makefile` handles version bumping, validation, and releases:

```bash
make validate         # JSON schema, structure, and plugin/marketplace version parity
make deploy           # marketplace patch bump + commit + tag + push
make deploy-minor     # marketplace minor bump + commit + tag + push
make deploy-major     # marketplace major bump + commit + tag + push
```

All `deploy*` targets refuse to run from a dirty tree or from a branch other than `main` (content commits land first, via a PR), then validate and only then bump the marketplace version, commit, tag, and push.

## Contributing

Issues and PRs welcome. The skills are opinionated toward real-world production patterns: additions should be backed by code that's actually deployed somewhere.

## License

See `LICENSE` at the repository root.
