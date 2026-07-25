# apresai Skills Marketplace

Production-ready Claude Code skills, mined from real production projects.

## Installation

```
/plugin marketplace add apresai/apresai-skills
```

After Claude Code reloads, the skills below are available via slash commands.

## Plugins (9)

| Plugin | Slash commands | What it does |
|---|---|---|
| **[apple-release](./plugins/apple-release/)** | `/release` · `/release-testflight` · `/release-xcodecloud` · `/app-store-audit` | iOS/macOS release automation to TestFlight + App Store Connect, plus a pre-submission audit against the **full saved App Store Review Guidelines** (1,832 lines, fetched from `developer.apple.com`). Audit detects empty usage descriptions, Privacy Manifest gaps, non-StoreKit payments in digital-content apps, web-view-only apps, ATS exceptions, and more — every finding cites the exact guideline ID with verbatim rule text. |
| **[bubbletea-design](./plugins/bubbletea-design/)** | (skill auto-triggers) | Build beautiful Go TUIs with **Bubble Tea v2 / Bubbles v2 / Lip Gloss v2**. Architecture patterns, component catalog, styling recipes, async/streaming patterns, v1→v2 migration map, 33 gotchas, 13 patterns. Includes real-world recipes mined from production CLIs. |
| **[chad-review](./plugins/chad-review/)** | `/chad-review` | 6-pass autonomous pre-commit code review: drift, behavior-and-risk, tests, observability, dependency-freshness, simplification. One pass per question, so no defect is reported twice, and every sub-check (`[spec/query]`, `[types]`, `[routes]`, `[datamodel]`, `[docs]`, `[env]`, …) still reports or marks itself N/A. Project-agnostic: detects OpenAPI / codegen / route-parity conventions and marks absent ones N/A rather than failing. Diff-shape aware, so light and deps-only diffs skip the fan-out. Tuned for Claude Opus 5: one reviewer per language block plus one whole-project freshness agent (2 sub-agents, not 3), sub-agents report every finding with a confidence tag while the parent filters once with all findings in view, session-relative sonnet/opus tiering with an explicit model on every launch. Backs up untracked files before the fan-out and verifies they survived: the read-only guarantee is prompt-enforced, not tool-enforced, and a review once destroyed an untracked file under review; a tested `untracked-guard.sh` handles both halves. Cross-language: Go, TypeScript, Swift, Python. ~2-minute target on a standard diff, well under a minute on small shapes. |
| **[codex-br](./plugins/codex-br/)** | `/codex-br task` · `/codex-br review` · `/codex-br adversarial-review` | Run **OpenAI Codex on Amazon Bedrock** (`openai.gpt-5.5`, provider `amazon-bedrock`) instead of the default ChatGPT backend, via a `br` Codex profile. Delegate tasks, run the built-in reviewer, or run a steerable adversarial challenge review — all at max reasoning effort (`xhigh`), output returned verbatim. The Bedrock twin of OpenAI's `codex:*` plugin; includes one-time setup for the profile, the `~/.codex/.env` token pin, and the `codex-br` shell alias. |
| **[go-lambda](./plugins/go-lambda/)** | `/go-lambda-builder` | Go on AWS Lambda done right: `provided.al2023` + ARM64/Graviton2 + AWS SDK v2. Includes production patterns from 8+ real Lambda projects: bounded-timeout `LoadDefaultConfig`, STS session policies via `json.Marshal`, `TestSchemaDrift` reflection, ULID over UUID v4, OpenAPI-first via `oapi-codegen`, single-table DynamoDB with typed structs. |
| **[image-encoding](./plugins/image-encoding/)** | `/image-encoding` | Modern web image encoding with **AVIF** (primary, ~95% browser support) and **WebP** (fallback) via the `<picture>` cascade. Covers `cwebp` / `dwebp` / `avifenc` CLIs with current defaults, JPEG XL status, Next.js Image integration. |
| **[nextjs-opennext](./plugins/nextjs-opennext/)** | `/nextjs-deploy` | Next.js on AWS via **OpenNext v4 + CDK**. Includes production-mined patterns: `CachePolicyId` override (`4135ea2d-…`) required or CloudFront caches SSR forever, `WARM_PARAMS` env shape, Server-Components-only auth (no middleware / no Lambda@Edge), `__Secure-` vs `__Host-` cookie prefix behavior, cost-tag schema, NextAuth.js v5 RBAC, ISR DynamoDB GSI naming. |
| **[tidy](./plugins/tidy/)** | `/tidy` (skill also auto-triggers) | Applies the cleanups `/chad-review` reports but never performs: missed reuse, dead code, wrong-altitude logic, needless abstraction, defensive noise for states that cannot occur, compatibility scaffolding, comment rot. Scope-fenced to the current diff and behavior-preserving, proven by re-running the tests that were green before the edit; anything that turns one red is reverted rather than debugged into place, and anything needing a design decision is reported instead of applied. Pins an explicit model on every sub-agent rather than inheriting the session tier. Runs **before** `/chad-review`: editing after the gate puts unreviewed code on the path to main and re-arms the review. |
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
├── skills/<name>/                # multi-file skill (e.g. bubbletea-design, codex-br, tidy)
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

Issues and PRs welcome. The skills are opinionated toward real-world production patterns — additions should be backed by code that's actually deployed somewhere.

## License

See `LICENSE` at the repository root.
