---
name: chad-review
description: 6-pass autonomous pre-commit code review. Use when the user wants to review their changes before committing, asks for a pre-commit review, says "review before I commit" or "review the last commit", or invokes /chad-review. Reviews uncommitted working-tree changes (staged, unstaged, and untracked) if any exist; otherwise falls back to the last commit. Runs drift, behavior-and-risk, test, observability, dependency-freshness, and simplification analysis.
---

# Chad Review: 6-Pass Code Review

Autonomous review of uncommitted working-tree changes, or the last commit if the
tree is clean. Read-only except for running tests and type regeneration.

Each pass answers one distinct question, so no defect is reported twice:

| Pass | Question | Owner |
|---|---|---|
| 1. DRIFT | Two things that should agree, don't | reviewer agent |
| 2. BEHAVIOR AND RISK | What changed, and what breaks it | agent + parent |
| 3. TESTS | Do affected tests pass, and do tests exist | parent + agent |
| 4. OBSERVABILITY | Debuggable in production without a repro | reviewer agent |
| 5. FRESHNESS | Deps current, CVE-free, not end-of-life | own agent |
| 6. SIMPLIFY | Is it clean | reviewer agent |

**Model tiering is session-relative.** There is deliberately NO `model:`
frontmatter pin: the parent inherits the session model and each sub-agent carries
an explicit `model` computed per §"Model tiering", so a cheap session is never
force-upgraded for orchestration.

**Project-agnostic.** Spec, codegen, and doc checks look for common conventions
(`api.yaml`/`openapi.yaml`, generated artifacts at conventional paths,
route-parity tests). A missing convention reports
`N/A - convention not detected`, never a failure.

`resources/...` paths resolve against the skill root, not the project under
review: `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.

## Pre-flight

1. `git status --porcelain`.
2. **Select the target.** Any uncommitted change (staged, unstaged, or
   untracked) means review the working tree: `git diff HEAD --stat` and
   `git diff HEAD` for tracked files, plus Read each `??` file and treat it as a
   new-file addition. A clean tree means review the last commit: `git log -1
   --format='%H %s'`, then `git show --stat HEAD` and `git show HEAD`. No commits
   and a clean tree means say "Nothing to review" and STOP. Either way, build the
   **changed files list**.

   **Back up untracked files first.** This skill's read-only guarantee is
   enforced by prompt wording, not by tool restriction: the reviewer agents are
   `general-purpose` and language specialists holding Bash, Edit, and Write, and
   the review runs the project's own test and codegen commands. On 2026-06-14 a
   review sub-agent "restored" the tree with a git command that sweeps untracked
   files; an untracked test file under review was gone from disk afterwards while
   the review reported success. Any of those paths can do it, so back them up on
   every working-tree review, including the `light` shape.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" backup
   ```

   It prints the backup path; **put that path in the report header** so the files
   are recoverable even if this session dies. A non-zero exit means something
   could not be backed up: stop and tell the user rather than reviewing an
   unprotected tree. That includes exit 127 on an install predating the script
   (unlike `chad-review-route.sh`, this one has no fallback and is not meant to
   have one: routing degrades to a worse default, but skipping the guard silently
   drops the only thing standing behind the read-only guarantee).

3. **Announce the target and tier** in one line, mapping your session model per
   §"Model tiering":
   `Chad Review: working tree (2 staged, 3 unstaged, 1 untracked), opus session, MECH=sonnet JUDGE=opus`
   If the session model is undeterminable, use the `unknown` row and say so.
4. The diff feeds passes 1, 2, 3 (coverage), 4, and 6. The changed files list
   drives test selection. Pass 5 is whole-project: it audits dependencies
   regardless of the diff, reading the file list only to prioritize and tag.
5. **Classify the diff shape.** Ambiguity always falls to `standard`.

   - `light`: **docs-only** (`*.md`, `*.txt`, `docs/**`, LICENSE, images),
     **config-only** (`.github/**`, `.gitignore`, `.editorconfig`, linter
     configs; not manifests, not IaC), or **tiny** (at most 4 files AND at most
     40 changed lines of non-test production code).
     **Forced to `standard` regardless**: `CLAUDE.md`, any `*/SKILL.md`,
     anything under `.claude/`, a `prompts/` dir, or a plugin's `commands/`,
     `agents/`, or `skills/` dir. Here those are executable behavior, not prose.
   - `deps`: only manifests and lockfiles (`go.mod`/`go.sum`, `package.json` +
     lockfile, `pubspec.*`, `Package.swift`/`Package.resolved`, `Cargo.*`,
     `pyproject.toml`/`requirements*.txt`).
   - `standard`: everything else.

   | Shape | Agents | Treatment |
   |---|---|---|
   | `light` | 0, or 1 if the FRESHNESS census returns work | Every pass runs INLINE in the parent, FRESHNESS aside; a small or prose-only diff does not justify an agent bootstrap. Because no reviewer fans out, the parent is both author and filter: apply the Phase 2 filter discipline to your own findings, and report `Filtered: N raised, M dropped` as usual. On docs-only the doc is the subject, so DRIFT leads (accuracy against the code, staleness) and BEHAVIOR AND RISK is a quick probe for secrets, PII, or wrong commands. On config-only, CI and workflow changes ARE behavior: probe them properly (a `pull_request_target` trigger running untrusted PR code with secrets, a permissions widening, a cache-poisoning path). FRESHNESS takes the cache path; a cold or stale cache forces a full run, and the census then decides whether that full run needs an agent at all or finishes inline. |
   | `deps` | 1 | FRESHNESS runs FULLY FRESH as a sub-agent, every dep tagged `(diff-touched)`. TESTS runs in the parent, since bumps break tests. Others: one-line inline notes or N/A. |
   | `standard` | 1 per language block + 1 | Full fan-out per §"Execution strategy". |

   Print `Diff shape: <shape>`. When it is not `standard`, add "rerun with
   `/chad-review --full` to force the complete fan-out". `--full` skips
   classification and treats the diff as `standard`.
6. **Route by language family:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/chad-review-route.sh"
   # last-commit mode: ... chad-review-route.sh --last-commit
   ```

   It emits one routing block per detected language (Go, CDK TypeScript,
   Next.js/React, generic TS/JS, iOS Swift, OpenAPI/docs, plus a catch-all so no
   file is silently dropped), each naming a reviewer `subagent_type`, a codegen
   and spec-lint hint derived from the project's own Makefile targets, and
   Context7 hints derived from the imports and `package.json` deps the changed
   files actually use. It tells CDK from Next.js by imports and marker files, and
   finds OpenAPI specs by an `openapi:` key rather than a filename.

   **Mixed-language diffs**: spawn ONE reviewer per block plus ONE whole-project
   FRESHNESS agent (CDK + Go = 3 agents). **Scope the diff per block**: each
   reviewer sees ONLY that language's hunks. DRIFT's codebase-wide grep is
   scope-independent, and the parent and FRESHNESS agent still see everything.
   All findings merge into one report.

   If the script is missing, fall back to the picks in §"Execution strategy".
7. **Run the project's own gate, in the parent, before any agent launches.**

   Deterministic checks are the cheapest defect detector this skill has and the
   only one that cannot hallucinate. Whatever the gate catches costs no agent at
   all, and its output narrows what the agents are then asked to look at. It runs
   on every review including `light` and `deps`; it is not shape-gated.

   Discover it by evidence, first hit wins, and never by assuming `make`:

   - a Makefile target matching `^(validate|check|verify|ci)$`
   - a `package.json` script named `validate` or `check`, or `lint` plus
     `typecheck`
   - a `justfile` recipe or `Taskfile.yml` task of those names
   - the `run:` steps of `.github/workflows/*.yml`, authoritative even when no
     local target exists
   - failing all of those, the language default for what the diff contains
     (`go build ./... && go vet ./...`, `tsc --noEmit`, `cargo check`,
     `swift build`)

   Print `Gate: <command> (<green | N failures | none detected>)` in the report
   header beside `Diff shape:`. Cap it around 60s: past that report
   `Gate: <command> (over budget, not run)` and carry on rather than blocking a
   review on someone's full build.

   Failures are findings under the pass that owns them: compile, type, lint, and
   schema errors under DRIFT, failing tests under TESTS. Quote the tool's own
   output. Never paraphrase a compiler.

   **No gate at all is itself a finding**, reported once per review, MEDIUM,
   under TESTS:

   ```
   TESTS [gate] | <repo root> | no project validation entrypoint; add a validate target
   ```

   Put a ready-to-paste target in the fix prompt, assembled from
   `pass-reference.md` § GATE for the ecosystems actually present. Recommend it,
   never create it: the target belongs to the project and to whoever maintains
   it, and one this skill writes behind the maintainer's back is one nobody owns.
   Being a repo-level gap rather than a defect in the diff, it does not move the
   GO/NO-GO verdict, the same way a pre-existing FRESHNESS CRITICAL does not.

## 1. DRIFT

Everything that should agree, agrees: code with code, with spec, with generated
artifacts, with documentation. Catches what pre-commit hooks miss: dangling
references, query-param and response-shape drift, and prose that now lies.

Run DRIFT **before** TESTS. No point testing code that violates its contract.

**`[symbol]` Dangling references.** Parse the diff for removed or renamed
symbols (functions, types, structs, interfaces, variables, constants, exports).
Grep the codebase for surviving references, excluding `vendor/`,
`node_modules/`, `.git/`, `target/`, `build/`, `dist/`, `cdk.out/`, `.next/`,
and generated files (`*.generated.*`, `*_pb.go`, `*.pb.go`). A live reference to
a removed symbol is **CRITICAL**: the build is broken. A removed symbol still
named in docs is MEDIUM and reports under `[docs]`.

**`[spec/query]` `[spec/response]` `[spec/request]` API surface.** Scan the diff
for handler-level query-param reads, response writes, and request-body decoding
(per-language patterns in the reference). Find each handler's route in the
project's routing definition, locate the OpenAPI spec (`api.yaml`,
`openapi.yaml`, `openapi/*.yaml`, `docs/api.yaml`, `spec/openapi.yaml`), and
resolve `$ref` when checking schemas. Flag any param, response key, or request
field present in code but absent from the spec, and any required spec field
missing from code. A public API change with no matching spec update is
**CRITICAL**.
Report: `DRIFT [spec/query] | api.yaml | param "fresh" read in HandleLeaderboard, absent from GET /groups/{id}/leaderboard`

**`[types]` Generated artifact freshness.** Detect type generation via the
reference patterns, run it, then `git diff` the generated paths
(`*.generated.{ts,go,swift,kt}`, `*_gen.*`, `generated/`, `**/types/api.*`).
Changes after regeneration mean the committed types are stale.

**`[routes]` Route parity.** Find a route-parity test (`TestRoutesMatchSpec`,
`test_routes_match_spec`, `routes.test.ts`, or a filename containing "parity" or
"spec match") and run it scoped. Quote any mismatched routes.

**`[spec/lint]` Spec validation.** Run the project's spec validation command if
one exists (`make validate-openapi`, `npm run lint:openapi`, `spectral lint`),
plus any struct-to-spec validator script.

**`[datamodel]` Data model docs.** Scan persistence-layer diffs (`db/*.go`,
`prisma/schema.prisma`, `models.py`, `migrations/`) for new key patterns, entity
prefixes, and table or column additions, then check `docs/data-model.md`,
`docs/dynamodb-data-model.md`, `docs/database.md`, `docs/schema.md`, or
`ARCHITECTURE.md`. A new entity, table, or key pattern with no doc entry is
**HIGH**.

**`[docs]` `[env]` `[comments]` Prose and contracts.** For each change, decide
which docs should reflect it: README setup and build commands, architecture docs,
ADRs, runbooks, CHANGELOG for user-visible behavior, infrastructure and on-call
docs. Updated in the same diff is OK; existing but untouched means read it and
flag what this change made stale; missing entirely for a surface that warrants
one is a finding.

- **HIGH** `[env]`: a new env var, config flag, or setup step with no
  `.env.example` or README update.
- **HIGH** `[docs]`: changed behavior contradicts an existing doc statement. The
  doc now lies.
- **MEDIUM** `[comments]`: a new exported symbol with no doc comment (godoc,
  TSDoc, Swift `///`, docstring).
- **MEDIUM** `[docs]`: a removed symbol still referenced in docs.
- **LOW**: docs that could be clearer but are not wrong.

> Grep patterns, language-server escalation, codegen detection, API-surface
> patterns, and doc-comment conventions: `pass-reference.md` § DRIFT.

## 2. BEHAVIOR AND RISK

Every behavior change is intentional, safe for existing data, and survives a
hostile reading. The reviewer agent establishes what changed; the parent runs the
attacks with every other finding already in view.

**What changed.** Assess what the code *does* differently, not which lines moved.
Narrate one sentence ONLY for files carrying a CRITICAL or HIGH flag; summarize
the rest as a count ("6 other files: behavior-preserving refactors").

**CRITICAL** if a change could corrupt existing records (wrong defaults, changed
attribute types, renamed keys); break backward compatibility with older clients
(removed fields, changed response shapes, modified enums); alter authentication
or authorization (middleware, token validation, permission checks); or change
data migration behavior (bulk updates, backfills, schema transformations).
**HIGH** if it alters sort order, ranking, or scoring, or changes notification or
push behavior.

Error handling that silently swallows failures belongs to OBSERVABILITY. Do not
report it twice.

**Attacks.** Probe as a malicious user, a race condition, or production data that
does not match test assumptions:

- **Requirements**: read the spec or ticket as a hostile lawyer. Do two rules
  contradict? Is an absolute ("always", "never") revoked elsewhere? If the diff
  silently resolves a spec contradiction, that is MEDIUM or higher: state the
  resolution chosen and flag it. A flawless implementation of a broken spec is
  still broken.
- **Auth**: what request now 401s or 403s that didn't? Expired, missing, or
  wrong-provider tokens?
- **Empty and nil**: empty, nil, zero-length, missing optional fields, empty
  array versus null.
- **Production versus test data**: shape assumptions that hold in tests only, old
  records missing new fields, unexpected enum values.
- **Concurrency**: can two simultaneous requests race, double-write, or leave
  inconsistent state?
- **Backward compatibility**: would an older client break, crash, or show wrong
  data?
- **Boundaries**: max values, very long strings, Unicode, special characters,
  time zones, midnight edges.
- **Injection**: SQL/NoSQL, command, XSS, path traversal, SSRF in any new path
  consuming user input.

Rate CRITICAL (data loss, security bypass, or production crash), HIGH
(user-visible bugs under realistic conditions), MEDIUM (edge case that bites
eventually), LOW (theoretical but worth noting).

> Language gotchas (Go nil maps and goroutine leaks; TS hydration,
> undefined-versus-null, `as` assertions; Swift IUO, Sendable, actor reentrancy;
> Python mutable defaults and async exceptions): `pass-reference.md` § BEHAVIOR
> AND RISK.

## 3. TESTS

The tests covering this change run green, and tests exist for what changed. A
green run over zero tests is not a passing review.

**`[gate]`** lives here too, one level up from a missing test: a repo with no
validation entrypoint at all, per pre-flight step 7. Report it once, MEDIUM, with
the proposed target in the fix prompt.

**Run (parent).** Identify test files for the modified files (Go `*_test.go` in
the same package; TS co-located `*.test.*`/`*.spec.*` or `__tests__/`; Python
`test_*.py`/`*_test.py`; Swift test targets importing the module; Rust
`#[cfg(test)]` or `tests/`) and run only those, scoped per the reference. All
pass: say so. Any fail: show the output, read the failing test and the code it
tests, and propose a fix marked "Proposed fix, NOT applied". Never edit, never
auto-apply.

**Coverage (reviewer agent).** For each new or modified exported function,
handler, or method, check whether a test references it by name. For each new
branch, error case, or feature flag, check whether a test exercises it. For bug
fixes, verify a **regression test** exists: one that would have failed before the
fix. For every new or modified test, confirm it **can fail**: the assertion
depends on the changed path, is not tautological, and the subject is not mocked
away. A test that cannot fail counts as missing coverage.

- **CRITICAL**: new public endpoint, HTTP handler, Lambda entry point, or cron
  entry point with zero tests.
- **HIGH**: new business-logic branch with no test; bug fix with no regression
  test.
- **MEDIUM**: modified function whose existing tests don't cover the new
  behavior.
- **LOW**: internal helper covered only transitively by caller tests.

> Per-language scoping commands and what "covered" looks like:
> `pass-reference.md` § TESTS.

## 4. OBSERVABILITY

Production issues here can be diagnosed without a repro. For each new or modified
path check for structured logging at entry and exit of significant operations;
error wrapping that carries context up the stack; request, user, and correlation
identifiers; key decision points logged ("cache hit", "falling back to provider
X"); and metrics or timings for rate-limited, queued, retried, or
externally-dependent operations.

- **CRITICAL**: an error path that silently swallows failures
  (`if err != nil { return nil }`, empty `catch`, ignored promise rejection, bare
  `except: pass`). This is the single home for the silent-failure check, and it
  covers **modified** handling as well as new: a change that turns a propagated
  error into a swallowed one is the same defect, and often better hidden.
- **HIGH**: a new handler, background job, or entry point with no logging;
  an error returned without wrapping, making root cause untraceable; PII,
  credentials, or tokens logged in plain text.
- **MEDIUM**: a slow operation (DB query, external call, S3 put) with no timing
  or metric; log lines or metrics removed in the diff (confirm intent).
- **LOW**: a missing debug log on a branch that would aid troubleshooting.

For Lambda, CloudWatch, or equivalent targets, confirm logs carry enough context
to correlate with the triggering request.

> slog, pino, OSLog, structlog, and Lambda logging idioms:
> `pass-reference.md` § OBSERVABILITY.

## 5. FRESHNESS

Every direct dependency, framework, and runtime is current enough to be safe,
carries no known CVE and no end-of-life runtime, and each staleness call
separates an overdue or security-driven upgrade from one still too early to take.

FRESHNESS is a WHOLE-PROJECT audit. It runs on every review regardless of what
the diff touches, reading the changed-files list only to prioritize and tag, never
to gate whether the pass runs.

**0. Census, in the parent, deterministic, about a second.** The unit of work is
anything this project depends on that can go stale, which is NOT the same as
anything carrying a manifest filename. A pure manifest allowlist reports a clean
bill on a repo whose every file names an EOL runtime, because none of them is
called `package.json`. Three tiers, all pruning `vendor/`, `node_modules/`,
`.git/`, `target/`, `build/`, `dist/`, `.next/`, `cdk.out/`, `DerivedData/`,
`Pods/`.

- **Tier A, declared manifests.** `go.mod`/`go.sum`, `package.json` + lockfile,
  `pubspec.*`, `Package.swift`/`.resolved`, `Cargo.*`,
  `pyproject.toml`/`requirements*.txt`, `Gemfile.lock`, `composer.json`,
  `.tool-versions`, `.nvmrc`, `mise.toml`, `Podfile.lock`,
  `.terraform.lock.hcl`, a Homebrew formula or cask, `Dockerfile` `FROM` pins,
  `.github/workflows/*.yml` `uses:` pins, git submodule SHAs, devcontainer
  images, MCP server pins. Extract DIRECT dependencies plus the runtime
  constraint (`go` directive, `engines.node`, `environment: sdk`,
  `swift-tools-version`, `requires-python`, `rust-version`); step 3 scans
  transitives for CVEs. **This list is non-exhaustive on purpose**: a miss falls
  through to Tier B, never to N/A.
- **Tier B, pinned external references.** Grep the file set for the shape
  "external identifier plus a version or a date", keeping the surrounding line:
  `uses: x@v`, `FROM image:tag`, install URLs carrying a version path segment,
  runtime enums (`NODEJS_\d+_X`, `provided\.al\d+`, `python3\.\d+`), model IDs
  (`claude-*`, `amazon\.nova-*`, `openai\.gpt-*`, `gemini-*`), API version
  headers (`anthropic-version: 2023-06-01`), `swift-tools-version`, tool version
  claims ("Claude Code v2.1.198"), and date-stamped assertions ("as of
  2026-07-25", a pricing snapshot). This tier is what makes the pass work on
  doc, prompt, and IaC repos, whose versions never appear in a manifest.
- **Tier C, undeclared hard prerequisites.** Which external binaries must exist
  for the project's OWN entrypoints to run, that nothing declares. Read what the
  entrypoints execute, not what the repo's strings mention: a file-extension
  literal inside a classifier is not a dependency. POSIX utilities are not
  findings; a `jq` that the only test target depends on is.

**Polarity is not the census's job.** `NODEJS_20_X reached Lambda EOL
2026-04-30` is a correct warning telling readers to avoid it, not an EOL
finding, and a scanner that flags it is wrong in exactly the way a scanner that
suppresses it is wrong. The census collects candidates with their context;
deciding prescriptive versus cautionary versus historical is judgment, and it
belongs to the agent, or to the parent on the runs where no agent launches.

**1. Cache check, then decide who does the work.** Cache file:
`~/.claude/chad-review-cache/<sha256 of git remote get-url origin>.json`, keyed
by origin URL so every worktree shares it and nothing touches the repo. Schema:
`{ schemaVersion: 2, generatedAt, manifests: {<path>: <sha256>}, manifestSet: [sorted paths], censusEmpty, table, severityLines, scannerUsed, lastLocalScanClean }`.

- **FULL RUN** (steps 2 to 5, then write the cache) if ANY of: cache missing,
  unparseable, or carrying an unrecognized `schemaVersion`; manifest set differs
  from `manifestSet`; any hash differs; `generatedAt` older than 7 days; shape is
  `deps`; the diff touches a manifest. An unrecognized `schemaVersion` is a miss
  that OVERWRITES: a pre-v2 file is parseable JSON that can never satisfy the
  comparison above, so without this rule it forces the expensive path forever
  while looking like a warm cache.
- **CACHE HIT** otherwise: do NOT launch the sub-agent, do NOT call context7 or
  WebSearch. In the parent, re-run ONLY the local CVE scan, which is cheap and
  preserves same-day detection of new CVEs against unchanged deps. Clean means
  report the cached table headed "FRESHNESS (cached <date>, manifests unchanged;
  local CVE scan re-run this review: clean)". Anything new invalidates the cache
  and forces a full run. The 7-day TTL is safe because the security signal is
  never delayed; only latest-version and maturity data are cached, and their
  consumers are the 60-to-90-day windows below.

Key the cache on Tier A hashes only. Do NOT key it on the whole census: in a repo
whose content is prose, every PR touches some Tier B string and nothing would ever
hit. The census costs about a second in the parent, so re-running it fresh each
review is cheaper than the misses that would cause.

On a FULL RUN, the census decides who does the remaining work:

| Census result | Action |
|---|---|
| Empty across all three tiers | Report N/A **inline** and write the cache with `censusEmpty: true`, so the TTL applies and the next review converges instead of re-forcing a full run forever. Do NOT spawn. |
| Small, and answerable with no network, scanner, or polarity judgment | Do it inline, write the cache. |
| Anything needing context7, a vulnerability scanner, WebSearch, or polarity judgment | Spawn ONE agent, briefed WITH the census so it never repeats discovery. |

The N/A wording carries the evidence: `FRESHNESS: N/A - census scanned <N> files
across <M> ecosystems, zero version-bearing external references`. Never "no
recognized manifest detected", which reports an allowlist miss as a conclusion
and is how a repo full of EOL runtime strings earns a clean bill.

**2. Version resolution via context7.** Read each pinned version, then resolve
latest version, whether a migration guide exists, and how large the breaking
surface is (`resolve-library-id`, then `query-docs` on "latest version, migration
guide, breaking changes"). context7 is weak on release DATES: where recency or
patch count matters and it does not surface them, fall back to a lightweight
WebSearch ("<lib> <version> release date") purely to gauge recency. Soft-cap
lookups at about 12 to 15, prioritizing runtimes, core frameworks,
security-relevant deps, and diff-touched deps; list the rest as "not individually
version-checked this run".

**3. Security and EOL.** Run the ecosystem scanner (govulncheck, npm/pnpm audit,
pip-audit, cargo audit, `dart pub outdated --mode=security`) or the
language-agnostic `osv-scanner -r .`. If none is installed, say "security scan
unavailable: install osv-scanner/govulncheck" rather than reporting clean.
Cross-reference the runtime against end-of-life data (endoflife.date for Node,
Python, Go; the framework's own window for majors).

**4. Upgrade-timing judgment**, then **5. Report**.

### Upgrade-timing heuristic

**HOLD (too early, non-blocking)** when ALL hold: the gap is a MAJOR bump; the
latest major shipped recently (roughly under 60 to 90 days); context7 shows a
substantial breaking surface (many breaking changes or required codemods); and
the new major has few patches so far (still x.0.0 or x.0.1, fewer than about 3).

**UPGRADE** when ANY hold: the current version has a known CVE, or the runtime or
framework major is end-of-life or out of support (CRITICAL, overrides any HOLD);
the latest is MATURE (shipped over ~90 days ago, at x.2 or x.3 with several
patches); the gap is only MINOR or PATCH with no breaking surface; or the current
major is itself losing support soon.

**Pre-1.0 caution:** under semver a 0.y to 0.(y+1) bump is breaking, so treat it
as major-equivalent. A brand-new 0.x minor with no follow-up patches is a HOLD.

### Severity and disposition

Severity reflects RISK; the **disposition** is the more important output. An
outdated framework is a finding to ACTION, not debt to launder into a backlog
nobody reads. Every safe upgrade deferred compounds into a riskier big-bang
migration later, which is the whole reason this pass exists.

- **CRITICAL**: known CVE, or an end-of-life or unsupported runtime or framework
  major. Overrides any HOLD.
- **HIGH**: a core framework or runtime one or more majors behind AND in support
  sunset, even without a CVE.
- **MEDIUM**: a core framework or important direct dependency meaningfully behind
  (a major, several minors, or years stale) where the target is mature and no
  breaking HOLD applies. The bread-and-butter finding, and it is **do-now**.
- **LOW**: a single patch behind on a non-core dependency. A *stack* of "only a
  minor behind" deps is not trivial in aggregate; surface the batch.

One disposition per flagged dependency:

- **UPGRADE NOW (safe)**: the DEFAULT for any HIGH or MEDIUM whose target is
  mature and not under a HOLD. Do NOT backlog it. Recommend doing it in this
  change or an immediate fast-follow, and **offer to perform it** (bump, build,
  run the affected suite). Catching yourself backlogging a mature, safe framework
  upgrade means re-classifying it as UPGRADE NOW.
- **SCHEDULE**: a CRITICAL or EOL the diff did not touch and that cannot be done
  safely inside this commit. A dated follow-up, never a silent backlog.
- **HOLD**: a brand-new breaking major, with a revisit signal ("after x.2",
  "+90d"). The only disposition that means wait.
- **BACKLOG**: LOW trivial lag only.

### Report format

One row per dependency that is behind or flagged; summarize current-and-clean
deps as a closing count.

| Dependency | Current | Latest | Behind | Maturity / Released | Security | Recommendation |
|---|---|---|---|---|---|---|
| next | 14.2.30 | 15.0.1 | 1 major | ~3 wks ago, 1 patch, large App Router migration | clean | HOLD (revisit after 15.2 or +90d) |
| react | 18.3.1 | 19.1.0 | 1 major | mature: ~9 mo, at 19.1.x, modest migration | clean | UPGRADE NOW (safe), MEDIUM |
| golang.org/x/net | v0.21.0 | v0.38.0 | several minors | n/a | CVE reachable per govulncheck | UPGRADE NOW, CRITICAL (overrides hold) |
| node (runtime) | 18.x | 22.x LTS | runtime | n/a | EOL 2025-04-30 | UPGRADE NOW, CRITICAL (EOL) |

Then list every CRITICAL, HIGH, and **UPGRADE NOW (safe)** finding as severity
lines. Safe upgrades are the headline value of this pass; do not bury them:

- `FRESHNESS [security] | golang.org/x/net v0.21.0 | CVE reachable per govulncheck, upgrade to v0.38.0`
- `FRESHNESS [eol] | node 18 | end-of-life 2025-04-30, upgrade to 22 LTS`
- `FRESHNESS [upgrade-now] | mark3labs/mcp-go | 9 pre-1.0 minors behind, target mature and clean, bump now`
- `FRESHNESS [hold] | next 15.0.1 | shipped ~3 weeks ago, large migration surface, hold at 14.2.x`

Tag anything the diff touched with `(diff-touched)`. Zero issues means
"FRESHNESS: Clean. All direct dependencies current or within a safe lag, no CVE
and no end-of-life runtime." An empty census means "FRESHNESS: N/A - census
scanned <N> files across <M> ecosystems, zero version-bearing external
references."

> Ecosystem manifest, version, and security sources: `pass-reference.md` §
> FRESHNESS.

## 6. SIMPLIFY

The change is as small and as plain as it can be while still doing the job.
Quality only: correctness defects belong to BEHAVIOR AND RISK.

- **Reuse missed**: a new helper duplicating an existing one. Name the existing
  symbol and its path.
- **Dead code**: added-then-unused code, refactor leftovers, unreachable
  branches.
- **Wrong altitude**: a handler doing storage-shaped work, a data layer making
  presentation decisions.
- **Needless abstraction**: an interface with one implementation, a wrapper
  adding no behavior, generalization for a requirement that does not exist yet.
- **Defensive noise**: handling, fallbacks, or validation for states that cannot
  occur. Trust internal code and framework guarantees; validate at system
  boundaries only.
- **Compatibility scaffolding**: a feature flag or shim where the code could just
  change.

Severity caps at **MEDIUM**: nothing here is a correctness defect. Report, never
apply. The Fix Prompt hands these to `/tidy`.

> Per-language simplification signals: `pass-reference.md` § SIMPLIFY.

## Execution strategy

### Model tiering (session-relative)

**ALWAYS pass an explicit `model` on every Agent launch.** This is load-bearing:
since Claude Code v2.1.198 a launch with no explicit `model` silently inherits
the parent session tier.

- **MECH**: FRESHNESS and the parent's orchestration. **Always `sonnet`.**
- **JUDGE**: the reviewer agent (it owns behavioral review), the parent's attack
  probes, and CRITICAL re-verification. **`opus`, except a `sonnet` session stays
  `sonnet`.**

| Session model | Parent | MECH | JUDGE |
|---|---|---|---|
| opus | opus | sonnet | opus |
| sonnet | sonnet | sonnet | sonnet |
| fable | fable | sonnet | opus |
| unknown / haiku / other | = session | sonnet | opus |

A sonnet session stays sonnet everywhere, so a deliberately cheap session is
never force-upgraded. A fable session keeps only the orchestration shell on fable
and runs the review on opus.

**Never haiku**: sonnet is the review floor. **Never spawn fable**: at roughly
double the Opus rate it buys no review advantage here. Use it only when asked for
by name. `opus` and `sonnet` are aliases resolved at spawn time; never hardcode a
dated model ID. Pricing snapshot 2026-07-25: Opus 5 $5/$25 per MTok, Sonnet 5
$3/$15, Fable 5 $10/$50.

### Effort

The Agent tool exposes `model` but **no `effort` parameter** (verified on Claude
Code 2.1.220; only the Workflow tool's `agent()` takes effort). Sub-agents inherit
the session effort, so effort is a session-level dial this skill cannot set per
pass. Use it deliberately: review accuracy holds well at lower effort, so run the
everyday pre-commit pass at `medium` and reserve `high` or `xhigh` for a review
that gates a release. It is the largest available speed lever and costs no code.

### Phase 1: fan out

Per language block, launch **one reviewer**, plus **one** whole-project FRESHNESS
agent for the review overall, all in ONE message (single-language = **2** Agent
tool uses; CDK + Go = **3**).

**Reviewer** owns passes 1, 2 (what changed), 3 (coverage only), 4, and 6, at the
JUDGE tier. `subagent_type` comes from the routing script
(`feature-dev:code-reviewer` for Go, `cloud-architect` for CDK,
`frontend-developer` for Next.js, `typescript-pro` for generic TS,
`code-reviewer` for Swift, `general-purpose` otherwise). It reads the diff ONCE
and emits each pass as its own labeled section, which is what keeps the
six-heading invariant intact. It needs tool access to run generators, spec
validators, and route-parity tests for DRIFT.

**FRESHNESS** is whole-project, MECH tier, `general-purpose`, launched ONCE per
review rather than per block, and only when the census in pass 5 step 1 returns
work an agent is needed for. On a `light` diff it is the only agent that can
launch. Brief it with **the census itself**, never with the discovery
instructions: it must not repeat a `find` the parent already ran, and handing it
the tier lists is what turns the spawn from a question into work. Add the
changed-files list used ONLY to prioritize and tag `(diff-touched)`, an explicit
note that the audit does not depend on the diff, context7 as primary with
WebSearch only as a recency probe, the instruction to judge polarity on Tier B
candidates rather than treating every version string as a finding, and the report
format above.

Wait for all Phase 1 results before proceeding.

### Phase 2: the parent pass

One pass, holding every finding at once:

1. **Run the tests.** Do not delegate: run them directly so output streams to the
   user and the parent has full context to propose fixes.
2. **Attack** (BEHAVIOR AND RISK, attack half) with targeted grep and file reads
   to confirm edge cases. This is JUDGE-tier work: inline when the parent is
   already there (opus and sonnet sessions), otherwise delegate this step alone
   to one JUDGE sub-agent.
3. **Filter once.** Sub-agents report unfiltered, so the parent is the only
   filter. Drop or downgrade ONLY on a `file:line` that disproves the finding,
   never on plausibility. Classic false-positive causes: a grep hit inside a
   comment, string literal, test fixture, or generated file; a "missing test"
   covered by a differently named or integration test; a "stale doc" statement
   that still holds; a behavior change intended per an adjacent comment or the
   commit message. Emit one `Filtered: N raised, M dropped` line. A dropped
   CRITICAL stays visible as `[dropped: <=10-word evidence]`.
4. **Re-verify CRITICALs.** Any CRITICAL, and anything marked `CONF lo`, gets a
   second look against the code before it enters the verdict. This step can
   confirm a finding, or sharpen its file:line, or downgrade its severity. It
   **cannot** drop it: failing to confirm is not evidence of absence, and only
   step 3's rule removes a finding. An unconfirmed CRITICAL stays in the report,
   marked `[unconfirmed]`, and still counts toward the verdict.
5. **Confirm the working tree survived.**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" verify --restore
   ```

   Exit 0 means every untracked file the guard covers is still there, and its
   stdout line names any it does not cover: a path containing a literal newline
   cannot go through the line-based comparison, so the guard excludes it, says so
   on both stdout and stderr, and still exits 0. **Quote that line rather than
   summarizing it**, because for those paths exit 0 is not a survival guarantee.
   Exit 1 means one or more
   vanished during the review; `--restore` puts back the ones it can and names
   any it could not, which stay recoverable from the backup path it prints. Exit
   2 means the guard could not run at all (no backup was taken, or the tree is
   not a git repo): treat that as the backup step having failed and say so
   rather than reporting a clean tree. Report that at the top of the review as a CRITICAL **of the review
   process**, not of the diff, and state that the cause is unattributed: a
   sub-agent, a project test, or a codegen step could each have done it. It does
   not by itself move the GO/NO-GO verdict on the diff, which is judged on its
   own findings. Files that appeared during the review are new artifacts, not
   findings, and the script ignores them. Never issue a verdict on a tree you
   have not confirmed still holds the files you reviewed.
6. **Write the verdict.**

### Writing sub-agent prompts

The prompt contract (what every sub-agent prompt must contain, the verbatim
output contract, the prompt skeleton, and the Agent call shape) lives in
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/fanout.md`.

Read it when you are about to launch an agent, and only then: `standard` shape,
or `light`/`deps` where the FRESHNESS census returned work needing one. A `light`
review that spawns nothing never needs it, and `light` is the common case.

## Performance budget

Target: under ~2 minutes for a typical single-language change (5 to 10 files)
with a warm freshness cache; `light` and `deps` well under a minute, except a
`light` diff whose FRESHNESS census returns real work on a cold cache.

The levers in order of size: the diff-shape matrix skips the fan-out entirely for
most everyday changes; the deterministic gate catches the mechanical defects
before an agent is asked to look for them; the census keeps a spawn from
happening at all when there is nothing to audit; the freshness cache removes the
network-bound version loop; and a two-agent fan-out means wall-clock is the
slowest agent, not the sum.

Running long, cut in this order:

1. **FRESHNESS**: the cache is the primary lever. On a forced full run, cap the
   context7 loop first, or resolve only runtimes and core frameworks. NEVER skip
   the local security and EOL scan: a CVE or EOL runtime is CRITICAL and the scan
   is cheap.
2. **DRIFT `[types]` and `[spec/lint]`**: the most expensive sub-checks, since
   they compile or shell out. With no handler changes, mark the spec sub-checks
   N/A immediately without running generators.
3. **TESTS**: scope to `-run TestFunctionName` rather than `./...`; only packages
   containing changed files.
4. **DRIFT `[symbol]`**: scope grep with `--include` rather than all file types.

Never skip a pass to meet the budget. Mark a slow one with a note ("`[types]`
skipped: codegen takes over 30s, run `make generate-types` and check
`git diff`") rather than silently omitting it.

## Choosing between review tools

| Situation | Tool |
|---|---|
| About to commit or push; want the rigorous gate, a GO / NO-GO / CONDITIONAL verdict, and a fix prompt | `/chad-review` |
| Quality-only cleanup, applied, **before** the gate | `/tidy` |
| Quick read of one file or a change under three files | `/review` (built-in) |
| Code already in a GitHub PR; want inline PR comments and CI context | `pr-review-toolkit:review-pr` |

chad-review is for before the commit; pr-review-toolkit is for after the PR is
open. `/tidy` runs before chad-review, never after: applying edits after the gate
mutates the reviewed diff and re-arms it. The cycle is build, test, `/tidy`,
`/chad-review`, PR.

## Final report

Match length to findings: cover the substance, skip filler sections, restated
findings, and summaries of summaries. Lead with the outcome.

```
## Chad Review
Diff shape: <shape>
Gate: <command> (<green | N failures | none detected>)

### 1. DRIFT
[findings or "Clean"]

### 2. BEHAVIOR AND RISK
[behavior changes, then attack findings, or "Clean"]

### 3. TESTS
[run results and any proposed fixes, then coverage gaps, or "Clean"]

### 4. OBSERVABILITY
[gaps with severity, or "Clean"]

### 5. FRESHNESS
[currency table + CVE/EOL/UPGRADE-NOW lines, or "Clean"/"N/A"]

### 6. SIMPLIFY
[quality findings, capped at MEDIUM, or "Clean"]

Filtered: N raised, M dropped

### Verdict: [GO / NO-GO / CONDITIONAL]
[1-2 sentences: commit as-is, fix something first, or stop and rethink]
```

Carry each finding's wording verbatim. Steps 3 and 4 may lower a severity or
sharpen a `file:line`, and those edits carry through; nothing else is rewritten.
**Drop the `CONF` tag**: it is a routing signal for your filter, not something
the reader needs. A CRITICAL that step 4 could not confirm keeps its severity and
gains `[unconfirmed]`. Also **strip any process narration** an agent emitted
despite the contract. Findings in the deliverable, never the process.

**How FRESHNESS affects the verdict.** Being whole-project and always-on, a
pre-existing dependency issue unrelated to the diff should not hard-block an
unrelated commit:

- **CRITICAL on a dependency the diff touched or introduced: NO-GO.**
- **CRITICAL that is pre-existing and untouched: CONDITIONAL**, with a prominent
  callout. This change is safe to commit; the project carries a CRITICAL issue to
  schedule now.
- **HIGH (sunsetting major): CONDITIONAL** if urgent, otherwise advisory.
- **MEDIUM UPGRADE NOW findings: never silently backlogged.** A GO stays a GO,
  but the report surfaces them prominently, the Fix Prompt lists them with a
  verify step, and you OFFER to perform them in this change or a fast-follow.
  Backlogging a mature framework upgrade is the failure mode this pass prevents.
- **HOLD and single-patch LOW lag: advisory only.** Only these feed the BACKLOG.

## After the report: fix prompt

Offer a copyable **fix prompt** when the verdict is NO-GO or CONDITIONAL, or when
FRESHNESS produced UPGRADE NOW findings even on a GO, or when SIMPLIFY produced
findings. Keep it proportional; no filler. It must:

1. **List every finding needing action**, with pass, severity, file, and lines.
2. **Describe the outcome of each fix**, not the implementation ("ghost.go should
   use Eastern time for the race date, matching how live races work").
3. **Point at existing patterns** in this codebase that already do it right.
4. **Separate blocking from non-blocking, but fix all of them.** CRITICAL and
   HIGH block this commit; MEDIUM and LOW are fixed in the same change or an
   immediate fast-follow, never deferred to a backlog. The split is only about
   what blocks the merge. One exception: a FRESHNESS CRITICAL the diff did not
   touch is listed under required fixes labeled "schedule now, does not block
   this commit".
5. **Add a "Recommended, safe to do now" heading** for UPGRADE NOW findings, each
   with its concrete bump (`current -> target`) and a verify step, plus an
   explicit offer to perform them. Keep HOLD items out.
6. **Add a `/tidy` handoff line** when SIMPLIFY produced findings: name the files
   rather than restating each cleanup in prose. Exclude executable prompt content
   (`CLAUDE.md`, `*/SKILL.md`, `.claude/**`, `prompts/`, a plugin's `commands/`,
   `agents/`, `skills/`); `/tidy` refuses to edit those, so list them as manual
   follow-ups instead. Step 7 states the order.
7. **End with the loop that closes it**: apply the fixes, run `/tidy` if
   SIMPLIFY had findings, then run `/chad-review` again to confirm. Naming the
   order here is what keeps the tidy step from landing after the gate.

Then: ask "Want me to enter plan mode with this prompt, or do you want to edit it
first?" ONLY when the verdict is NO-GO or CONDITIONAL AND this is a direct
interactive session; enter plan mode with the prompt (or the user's edited
version). On a GO, print the report and end the turn without asking. As a
sub-agent, inside another skill (`/wrapup`), or headless, never block on a
question: the fix prompt is already in the report body.

## Rules

- NEVER edit a source file, commit, or apply a proposed fix. Show it only. The
  single exception is Phase 2 step 5 restoring a file that vanished during the
  review, which puts the tree back as it was rather than changing the diff.
- This read-only rule binds the sub-agents too, but it is only prompt-enforced:
  they hold Bash, Edit, and Write, and Phase 2 runs the project's own test and
  codegen commands. A `git stash -u`, `git clean`, or `git checkout` from any of
  those destroys untracked files under review. That is why pre-flight step 2
  backs them up and step 5 verifies they survived.
- NEVER silently skip a pass. All six appear as headings in every report. A pass
  may return early per the shape matrix, but only with the explicit line
  "N/A - not applicable to this diff shape (<shape>)". The same holds one level
  down: an absent convention says `N/A - convention not detected` rather than
  vanishing.
- ALWAYS pass an explicit `model` on every Agent launch, per §"Model tiering".
  Never haiku, never fable.
- **The prescribed agents are the entire budget**: one reviewer per language
  block plus one FRESHNESS agent. Never spawn an agent to verify or double-check
  another agent's finding; the parent does that in Phase 2. Never spawn a second
  agent for work one can finish.
- **Never spawn an agent to find out whether there is work.** Sub-agents do
  bounded work whose shape is already known. If a deterministic command in the
  parent answers the question, the parent answers it and passes the result down.
  A launch costs roughly 70k tokens before the agent reads a single line, almost
  all of it tool schema and brief, so an agent that returns "nothing to do" spent
  the entire bootstrap to deliver a fact a `find` would have produced for free.
  This is the rule behind the FRESHNESS census, and it applies to every pass.
- DRIFT may run type generators, spec validators, and route-parity tests. These
  are non-destructive.
- If the diff exceeds roughly 50 files or roughly 3000 changed lines, ask whether
  to scope the review to specific directories. The line count is the better
  signal on a repo of large files; the file count is the better signal on a wide
  refactor, so either trips the question.
