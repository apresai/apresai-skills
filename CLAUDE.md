# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this repository is

A Claude Code **plugin marketplace** published by apresai at
`github.com/apresai/apresai-skills`. Users install it with:

```
/plugin marketplace add apresai/apresai-skills
```

It is a content repository, not a software project. There is no build, no
test suite, and no application code. What ships is markdown: skill and
command definitions that get loaded into a Claude Code session, plus the
JSON manifests that let Claude Code discover them. The `Makefile` only
validates structure and tags releases.

The bar for content here is that it comes from something real. Skills are
mined from production projects and live API probes, not from
documentation summaries. When a plugin claims an API behaves a certain
way, that claim should trace to a verified observation.

## Repository structure

```
apresai-skills/
├── .claude-plugin/
│   └── marketplace.json     # the marketplace manifest; every plugin registers here
├── plugins/
│   ├── apple-release/
│   ├── bubbletea-design/
│   ├── chad-review/
│   ├── codex-br/
│   ├── go-lambda/
│   ├── image-encoding/
│   ├── nextjs-opennext/
│   ├── tidy/
│   └── xai-voice/
├── CLAUDE.md                # this file
├── LICENSE
├── Makefile                 # validate / package / version / release
└── README.md                # user-facing plugin table, kept current
```

`README.md` holds the authoritative per-plugin descriptions and the slash
commands each one exposes. Do not duplicate that table here; when a
plugin's behavior changes, update `README.md`.

## Plugin anatomy

Every plugin lives at `plugins/<name>/` and must contain
`.claude-plugin/plugin.json`. Everything else is optional and depends on
how the plugin is meant to be invoked:

```
plugins/<name>/
├── .claude-plugin/plugin.json   # required manifest
├── commands/<command>.md        # explicit slash commands
├── skills/<skill>/SKILL.md      # auto-triggering skill, may span several files
├── resources/                   # static assets shipped with the plugin
└── README.md                    # optional human-facing overview
```

**`commands/` versus `skills/` is the choice that matters**, and the
difference is not "explicit versus automatic."

- `commands/<name>.md` becomes the slash command `/<name>`. It runs only
  when someone invokes it.
- `skills/<name>/SKILL.md` auto-triggers when its frontmatter
  `description` matches what the user is doing, **and** is separately
  invocable as `/<name>`. A skill does not need a `commands/` directory
  to get a slash command. `codex-br` is the proof: it ships nothing but
  `skills/codex-br/SKILL.md` and is still invoked as `/codex-br task`.

So `skills/` is the more capable form for a single entry point, and it
lets a long reference span multiple files next to `SKILL.md`. Reach for
`commands/` when a plugin needs several distinct entry points that are
not one coherent skill, as `apple-release` does with five.

Both are discovered by convention from the directory layout; `plugin.json`
does not have to declare their paths.

Current split, useful when looking for a precedent to copy:

| Uses `commands/` | Uses `skills/` |
|---|---|
| apple-release (5 commands), chad-review, go-lambda, image-encoding, nextjs-opennext | bubbletea-design, codex-br, tidy, xai-voice |

A plugin can ship both. `apple-release` also ships `resources/` (the full
saved App Store Review Guidelines). `chad-review` and `image-encoding`
have no `README.md`, which is allowed.

A skill's `description` is load-bearing: it is the only thing deciding
whether the skill fires. Write it as trigger conditions, not as a summary.
`xai-voice` is the model to copy, enumerating the specific endpoints,
symbols, and user intents that should activate it.

### plugin.json

```json
{
  "name": "xai-voice",
  "version": "1.6.1",
  "description": "One paragraph. This is what users see when browsing.",
  "author": { "name": "Chad Neal", "email": "chad.neal@gmail.com" }
}
```

`name` is required by validation. If a `commands` key is present, every
path in it must start with `./`.

### Registering in marketplace.json

A plugin that is not listed in the root `.claude-plugin/marketplace.json`
is invisible to users, even if its directory is perfect. Add an entry:

```json
{
  "name": "xai-voice",
  "description": "Shown in the marketplace listing.",
  "version": "1.6.1",
  "author": { "name": "Chad Neal" },
  "source": "./plugins/xai-voice",
  "category": "ai-tooling"
}
```

The `version` here and the `version` in that plugin's `plugin.json` must
stay in sync. `make validate-versions` enforces this, and runs as part of
`make validate`, so a mismatch fails the check rather than shipping.

## Adding a new plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json`.
2. Add `commands/<name>.md`, or `skills/<name>/SKILL.md`, or both.
3. Register the plugin in `.claude-plugin/marketplace.json`.
4. Add a row to the plugin table in `README.md`.
5. Update this file: the repository-structure tree above, the
   `commands/` versus `skills/` split table, and the version range under
   Versioning. Three separate reviews have caught this file going stale
   because the checklist stopped at `README.md`.
6. If the plugin ships a `skills/` directory, add it to the Claude Desktop
   list in `README.md`: `make desktop` globs `plugins/*/skills/*`, so it
   will be packaged whether or not the docs say so.
7. Run `make validate`.

## Versioning

Two independent things carry versions.

- **The marketplace** has its own semver in the top-level `version` field
  of `marketplace.json`. Git tags track it (`v1.4.0` and so on).
- **Each plugin** has its own version, advancing at its own pace. As of
  this writing they range from 1.0.0 to 2.0.0. A plugin's version lives
  in two files that must agree: its own `plugin.json` and its entry in
  `marketplace.json`.

`make bump-patch` / `bump-minor` / `bump-major` move the **marketplace**
version only. They deliberately do not touch per-plugin versions; bump a
plugin by editing its two version fields directly as part of the change
that earned the bump.

## Makefile

```bash
make validate          # runs all four validate-* checks below
make validate-versions # plugin.json versions match their marketplace.json entries
make version           # print the current marketplace version
make bump-patch        # marketplace version only (also bump-minor, bump-major)
make clean             # remove stray .pyc / __pycache__ / .DS_Store
```

`make validate` is the check to run before opening a PR. It verifies that
`marketplace.json` is valid JSON with `name`, `owner`, and a `plugins`
array; that every `plugin.json` is valid JSON with a `name` and, if it
declares `commands`, that those paths start with `./`; that every
`skills/<name>/` directory contains a `SKILL.md`; and that every plugin's
version matches its `marketplace.json` entry with the two plugin lists
agreeing in both directions.

The `deploy` targets refuse to run from a dirty tree or from any branch
other than `main`, then validate and only then bump the marketplace
version, commit, tag, and push. Every validation step runs
before anything writes a version file, so a failed check never strands a
half-applied bump. A failure later in the commit/tag/push sequence still
can, and recovery depends on where it failed. If `git commit` was rejected,
the bump is staged but not committed, so restore from HEAD with
`git checkout HEAD -- .claude-plugin/marketplace.json`; the bare
`git checkout <path>` form restores from the index and does nothing. If the
commit succeeded and only the tag or push failed, the bump is already
committed, so re-run the release or unwind with `git reset --hard HEAD~1`
followed by `git tag -d v<version>` (the reset alone leaves the tag behind).
Since deploy pushes to `main` directly it is a
tagging step, not a review step: merge content through a PR first, then
release from `main`.

## Working in this repo

- Content changes go through a branch and a pull request, never a direct
  commit to `main`. PRs are squash-merged, one PR per reviewed change.
- Changing what a plugin does means updating three things in the same PR:
  the plugin content, its `description` in both manifests if the summary
  shifted, and its row in `README.md`.
- Removing a plugin means removing its directory, its `marketplace.json`
  entry, and its `README.md` row, then grepping the repository root for
  leftover references. A prior removal left stale docs behind for two
  months, which is why this line exists.
- Prose in this repository avoids em-dashes and emoji. Existing `Makefile`
  echo output predates that convention.
