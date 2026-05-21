# apresai Skills Marketplace

Production-ready Claude Code skills, mined from real production projects.

## Installation

```
/plugin marketplace add apresai/apresai-skills
```

After Claude Code reloads, the skills below are available via slash commands.

## Plugins (6)

| Plugin | Slash commands | What it does |
|---|---|---|
| **[apple-release](./plugins/apple-release/)** | `/release` · `/release-testflight` · `/release-xcodecloud` · `/app-store-audit` | iOS/macOS release automation to TestFlight + App Store Connect, plus a pre-submission audit against the **full saved App Store Review Guidelines** (1,832 lines, fetched from `developer.apple.com`). Audit detects empty usage descriptions, Privacy Manifest gaps, non-StoreKit payments in digital-content apps, web-view-only apps, ATS exceptions, and more — every finding cites the exact guideline ID with verbatim rule text. |
| **[bubbletea-design](./plugins/bubbletea-design/)** | (skill auto-triggers) | Build beautiful Go TUIs with **Bubble Tea v2 / Bubbles v2 / Lip Gloss v2**. Architecture patterns, component catalog, styling recipes, async/streaming patterns, v1→v2 migration map, 33 gotchas, 13 patterns. Includes real-world recipes mined from production CLIs. |
| **[chad-review](./plugins/chad-review/)** | `/chad-review` | 8-pass autonomous pre-commit code review — structural, behavioral, spec-drift, test, test-coverage, observability, documentation, adversarial. Project-agnostic (detects OpenAPI / codegen / route-parity conventions, marks sub-checks N/A when absent). Cross-language: Go, TypeScript, Swift, Python. 60-second target. |
| **[go-lambda](./plugins/go-lambda/)** | `/go-lambda-builder` | Go on AWS Lambda done right: `provided.al2023` + ARM64/Graviton2 + AWS SDK v2. Includes production patterns from 8+ real Lambda projects: bounded-timeout `LoadDefaultConfig`, STS session policies via `json.Marshal`, `TestSchemaDrift` reflection, ULID over UUID v4, OpenAPI-first via `oapi-codegen`, single-table DynamoDB with typed structs. |
| **[image-encoding](./plugins/image-encoding/)** | `/image-encoding` | Modern web image encoding with **AVIF** (primary, ~95% browser support) and **WebP** (fallback) via the `<picture>` cascade. Covers `cwebp` / `dwebp` / `avifenc` CLIs with current defaults, JPEG XL status, Next.js Image integration. |
| **[nextjs-opennext](./plugins/nextjs-opennext/)** | `/nextjs-deploy` | Next.js on AWS via **OpenNext v4 + CDK**. Includes production-mined patterns: `CachePolicyId` override (`4135ea2d-…`) required or CloudFront caches SSR forever, `WARM_PARAMS` env shape, Server-Components-only auth (no middleware / no Lambda@Edge), `__Secure-` vs `__Host-` cookie prefix behavior, cost-tag schema, NextAuth.js v5 RBAC, ISR DynamoDB GSI naming. |

## Versioning

The marketplace itself follows semver. Individual plugins evolve at their own pace — see each plugin's own version in `plugins/<name>/.claude-plugin/plugin.json`.

## How it's built

This is a Claude Code marketplace, not a software project. Each plugin lives under `plugins/<name>/` with:

```
plugins/<name>/
├── .claude-plugin/plugin.json   # plugin manifest
├── README.md                     # human-facing overview
├── commands/<name>.md            # slash command(s) + skill content
├── skills/<name>/                # multi-file skill (bubbletea-design only)
└── resources/                    # static assets (apple-release ships the
                                  # full App Store Review Guidelines here)
```

The `Makefile` handles version bumping, validation, packaging, and releases:

```bash
make validate         # JSON schema + structure check
make deploy           # patch bump + commit + tag + push
make deploy-minor     # minor bump + commit + tag + push
make deploy-major     # major bump + commit + tag + push
make desktop          # zip skills for Claude Desktop sideload
```

All `deploy*` targets require a clean working tree (content commits land first), then bump versions and tag.

## Claude Desktop sideload

For skills available on Claude Desktop (currently `bubbletea-design`), zip files are attached to each GitHub release:

```
https://github.com/apresai/apresai-skills/releases/latest
```

Download the `.zip` and add it via Claude Desktop's settings.

## Contributing

Issues and PRs welcome. The skills are opinionated toward real-world production patterns — additions should be backed by code that's actually deployed somewhere.

## License

See `LICENSE` at the repository root.
