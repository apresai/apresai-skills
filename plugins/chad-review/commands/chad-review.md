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
   | `light` | 0, or 1 on a cold cache | All six passes run INLINE in the parent; a small or prose-only diff does not justify an agent bootstrap. Because no reviewer fans out, the parent is both author and filter: apply the Phase 2 filter discipline to your own findings, and report `Filtered: N raised, M dropped` as usual. On docs-only the doc is the subject, so DRIFT leads (accuracy against the code, staleness) and BEHAVIOR AND RISK is a quick probe for secrets, PII, or wrong commands. On config-only, CI and workflow changes ARE behavior: probe them properly (a `pull_request_target` trigger running untrusted PR code with secrets, a permissions widening, a cache-poisoning path). FRESHNESS takes the cache path; if the cache is cold or stale, its rules force a full run, so launch the one FRESHNESS agent rather than skipping the pass. |
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

**0. Cache check.** Cache file:
`~/.claude/chad-review-cache/<sha256 of git remote get-url origin>.json`, keyed by
origin URL so every worktree shares it and nothing touches the repo. Schema:
`{ generatedAt, manifests: {<path>: <sha256>}, manifestSet: [sorted paths], table, severityLines, scannerUsed, lastLocalScanClean }`.
Run manifest discovery and hash each manifest AND its lockfile.

- **FULL RUN** (steps 1 to 5, then write the cache) if ANY of: cache missing or
  unparseable; manifest set differs from `manifestSet`; any hash differs;
  `generatedAt` older than 7 days; shape is `deps`; the diff touches a manifest.
- **CACHE HIT** otherwise: do NOT launch the sub-agent, do NOT call context7 or
  WebSearch. In the parent, re-run ONLY the local CVE scan, which is cheap and
  preserves same-day detection of new CVEs against unchanged deps. Clean means
  report the cached table headed "FRESHNESS (cached <date>, manifests unchanged;
  local CVE scan re-run this review: clean)". Anything new invalidates the cache
  and forces a full run. The 7-day TTL is safe because the security signal is
  never delayed; only latest-version and maturity data are cached, and their
  consumers are the 60-to-90-day windows below.

**1. Manifest discovery.** Find every manifest, pruning `vendor/`,
`node_modules/`, `.git/`, `target/`, `build/`, `dist/`, `.next/`, `cdk.out/`,
`DerivedData/`, `Pods/`. None recognized means report N/A and stop. Extract
DIRECT dependencies plus the runtime constraint (`go` directive, `engines.node`,
`environment: sdk`, `swift-tools-version`, `requires-python`, `rust-version`).
Skip transitive deps here; step 3 still scans them for CVEs.

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
and no end-of-life runtime." No manifest means "FRESHNESS: N/A, no recognized
manifest detected."

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
review rather than per block. On a `light` diff it is the only agent that
launches, and only when its cache rules force a full run. Brief it with the manifests discovered
project-wide (or the discovery instructions), the changed-files list used ONLY to
prioritize and tag `(diff-touched)`, an explicit note that the audit does not
depend on the diff, context7 as primary with WebSearch only as a recency probe,
and the report format above.

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
5. **Write the verdict.**

### Writing sub-agent prompts

Self-contained, always:

- One sentence of goal, naming the passes the agent owns.
- The diff. Sub-agents cannot see your conversation.
- Read `pass-reference.md` ONCE during prompt assembly and paste ONLY the
  sections for the passes this agent owns and the languages detected. Mandatory:
  skipping it silently degrades quality.
- The project's spec files, validation commands, test harness, and doc locations
  as detected in pre-flight. Absent ones stated as absent, so the agent reports
  that sub-check N/A.
- The output contract verbatim, and read-only instructions.

**Output contract (paste verbatim into every sub-agent prompt):**

```
Output. Strict, no exceptions:
- Zero preamble, zero restated diff, zero methodology narration.
- One line per finding:
  SEVERITY | CONF hi|med|lo | file:line | <=15-word finding
- Report EVERY issue you find, including ones you are uncertain about or
  consider low severity. Do NOT filter for importance or confidence. A later
  pass does that once, with every finding in view. Coverage is your job;
  ranking is not. Use CONF to say how sure you are.
- Emit one "## <PASS NAME>" heading per pass you own, findings underneath,
  in the order the passes are numbered.
- A pass with no findings outputs exactly: Clean
- A sub-check whose project convention is absent outputs exactly:
  TAG | N/A - convention not detected
(FRESHNESS agent: emit the recommendation table first, that is data, then the
 severity and UPGRADE-NOW lines as TAG | dep | <=15-word recommendation.)
```

Prompt skeleton:

```
You are reviewing a pre-commit diff on the <project> repo. You own passes
1 DRIFT, 2 BEHAVIOR (what changed), 3 TESTS (coverage only, do not run tests),
4 OBSERVABILITY, and 6 SIMPLIFY.

The diff under review (from `git diff HEAD` + untracked files):
<paste diff>

Project context (detected during pre-flight):
- OpenAPI spec: <path or "not present">
- Type-generation command / spec lint command: <or "not present">
- Route-parity test: <command or "not present">
- Data-model doc: <path or "not present">

Pass rubrics for the languages in this diff:
<paste the matching pass-reference.md sections>

<paste the output contract>. Read-only: do not edit files or run commits.
```

Agent call. `model` is REQUIRED, from §"Model tiering":

```json
{
  "description": "Reviewer: DRIFT, BEHAVIOR, TESTS coverage, OBSERVABILITY, SIMPLIFY",
  "subagent_type": "feature-dev:code-reviewer",
  "model": "<JUDGE tier for this session>",
  "prompt": "<self-contained prompt as above>"
}
```

## Performance budget

Target: under ~2 minutes for a typical single-language change (5 to 10 files)
with a warm freshness cache; `light` and `deps` well under a minute, except a
`light` diff that hits a cold freshness cache and has to run that pass fresh.

The levers in order of size: the diff-shape matrix skips the fan-out entirely for
most everyday changes; the freshness cache removes the network-bound version loop;
and a two-agent fan-out means wall-clock is the slowest agent, not the sum.

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

Carry each finding's wording verbatim. Step 4 may sharpen a `file:line` or
lower a severity, and those edits carry through; nothing else is rewritten.
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
   rather than restating each cleanup in prose. Order it correctly, because
   `/tidy` must not run after a gate whose verdict it would invalidate: run
   `/tidy`, then re-run `/chad-review` so the review sees the final diff. Fold
   this into the step 7 verification line rather than implying tidy runs last.
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

- NEVER edit a source file, commit, or apply a proposed fix. Show it only.
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
- DRIFT may run type generators, spec validators, and route-parity tests. These
  are non-destructive.
- If the diff exceeds roughly 50 files or roughly 3000 changed lines, ask whether
  to scope the review to specific directories. The line count is the better
  signal on a repo of large files; the file count is the better signal on a wide
  refactor, so either trips the question.
