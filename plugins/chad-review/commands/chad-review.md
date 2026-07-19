---
name: chad-review
description: 9-pass autonomous pre-commit code review. Use when the user wants to review their changes before committing, asks for a pre-commit review, says "review before I commit" or "review the last commit", or invokes /chad-review. Reviews uncommitted working-tree changes (staged, unstaged, and untracked) if any exist; otherwise falls back to the last commit. Runs structural, behavioral, spec-drift, test, test-coverage, observability, documentation, adversarial, and dependency-freshness analysis.
---

# Chad Review — 9-Pass Code Review

Autonomous review of uncommitted working-tree changes — or the last commit if the tree is clean. Read-only except for running tests and type regeneration. Never edit source files, never commit.

**Model tiering is session-relative, not hardcoded.** There is deliberately NO `model:` frontmatter pin: the parent turn (pre-flight, Pass 4, report assembly) inherits the session model, and each sub-agent pass carries an explicit `model` computed from the session model per §"Model Tiering". This means chad-review never force-upgrades a cheap session upward for orchestration, and escalates to a premium model only where merge-gating judgment lives. (This reverses the older "pin opus so a Fable session isn't under-powered" rule: a Fable parent is now intended — judgment escalates to opus per-pass instead of the whole turn riding opus.)

This skill is project-agnostic. It detects the language and framework of the changes under review and adapts. For project-specific spec/contract checks, it relies on conventions (OpenAPI spec at `api.yaml` or `openapi.yaml`, generated type artifacts at conventional paths, route-parity tests if they exist). When a convention doesn't match the current project, the corresponding sub-check is reported as "N/A — project convention not detected" rather than failing.

Every `resources/...` reference in this document resolves relative to the skill/plugin root, NOT the project under review: `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`. Read them from there.

## Pre-flight

1. Run `git status --porcelain` to detect uncommitted changes.
2. **Select the review target:**
   - **If there are any uncommitted changes** (staged, unstaged, or untracked) → review the working tree:
     - Run `git diff HEAD --stat` and `git diff HEAD` to capture modifications to tracked files (covers both staged and unstaged).
     - For each untracked file (lines starting with `??` in `git status --porcelain`), use Read to load the file and treat its contents as a synthetic new-file addition in the review input.
     - Build the **changed files list** from all tracked modifications plus untracked files.
   - **If the working tree is clean** → review the last commit:
     - Run `git log -1 --format='%H %s'` to identify it. If the repo has no commits, tell the user "Nothing to review — working tree is clean and there is no commit history" and STOP.
     - Run `git show --stat HEAD` and `git show HEAD` to capture the summary and full diff.
     - Build the **changed files list** from the files touched by that commit.
3. **Determine the session model tier and announce the target** in one line. Read your own session model from the environment/system context, map it to MECH/JUDGE tiers per §"Model Tiering", and print both, e.g.:
   - `Chad Review — reviewing working tree (2 staged, 3 unstaged, 1 untracked) — opus session → MECH=sonnet, JUDGE=opus`
   - `Chad Review — reviewing last commit a1b2c3d "Fix credit refund race" — fable session → MECH=opus, JUDGE=opus`
   If you cannot determine the session model, use the `unknown` row (MECH=sonnet, JUDGE=opus) and say so.
4. The captured diff is the input for Passes 1 through 8. The changed files list drives Pass 4 test selection and Pass 5 coverage selection. Pass 9 (FRESHNESS) is whole-project: it audits the project's dependencies regardless of the diff, and reads the changed files list only to prioritize and tag deps the change touched.
5. **Classify the diff shape** from the changed-files list. Ambiguity always falls to `standard`:
   - `docs-only`: every file matches `*.md`, `*.txt`, `docs/**`, LICENSE, or images. Exceptions that force `standard`: `CLAUDE.md`, any `*/SKILL.md`, anything under `.claude/`, a `prompts/` dir, or a plugin's `commands/`, `agents/`, or `skills/` dir (in this ecosystem those are executable behavior, not prose).
   - `config-only`: only `.github/**`, `.gitignore`, `.editorconfig`, or linter configs. Not dependency manifests, not IaC.
   - `deps-only`: only dependency manifests/lockfiles (`go.mod`/`go.sum`, `package.json` + lockfile, `pubspec.*`, `Package.swift`/`Package.resolved`, `Cargo.*`, `pyproject.toml`/`requirements*.txt`).
   - `tiny`: at most 4 files AND at most 40 changed lines of non-test production code. (Widened from the original 2 files / 10 lines so more everyday small PRs run all passes INLINE in the parent and skip the fan-out entirely — the executable-file exceptions below still force `standard`.)
   - `standard`: everything else.

   Per-shape pass matrix. Every one of the 9 passes still appears as a heading in the Final Report; non-`standard` shapes replace the sub-agent fan-out with the listed treatment:

   | Shape | Sub-agents | Treatment |
   |---|---|---|
   | docs-only | 0-1 | Passes 1, 2, 4, 5, 6: report the literal line "N/A — not applicable to this diff shape (docs-only)". Pass 3: only 3f, and only if a data-model doc changed. Pass 7 runs INLINE in the parent (the doc change itself is the review subject: accuracy vs code, staleness). Pass 8: brief inline probe (secrets/PII/wrong commands in the new text). Pass 9: cache path (step 0). |
   | config-only | 0-1 | Passes 2 and 8 run inline in the parent (CI/workflow changes are behavior, e.g. `pull_request_target` foot-guns). 1, 3, 4, 5: N/A. 6, 7: inline quick checks. 9: cache path. |
   | deps-only | 1 | Pass 9 runs FULLY FRESH as a sub-agent (this is the shape it exists for), every dep tagged `(diff-touched)`. Pass 4 runs in the parent (bumps break tests). 1, 2, 3, 5, 6, 7: N/A or one-line inline notes. |
   | tiny | 0-1 | All 9 dimensions still evaluated, but Passes 1, 2, 3, 5, 6, 7 run INLINE in the parent turn instead of as sub-agents (a small diff does not justify agent bootstraps). Pass 9: cache path. |
   | standard | bundled fan-out (3 per language block) | Phase A/B/C strategy below: one mechanical-bundle agent (Passes 1,3,5,6,7) + one Pass 2 specialist per language block, plus one whole-project Pass 9, with session-relative model tiering and the freshness cache applied. |

   Print `Diff shape: <shape>` in the report header. When the shape is not `standard`, add: "rerun with `/chad-review --full` to force the complete fan-out". `--full` (or the user asking for a full review) skips classification and treats the diff as `standard`.
6. **Route per-pass agents by language family.** Run the bundled
   `chad-review-route.sh` script to detect which language families
   appear in the changed-files list and print recommended per-pass
   `subagent_type` + Context7 hints:

   ```bash
   # When installed as an apresai-skills plugin:
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/chad-review-route.sh"
   # Or last-commit mode:
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/chad-review-route.sh" --last-commit
   ```

   The script emits one routing block per detected language (Go, CDK
   TypeScript, Next.js/React, generic TypeScript/JS, iOS Swift,
   OpenAPI/docs, plus an explicit catch-all for anything unclassified —
   it never silently drops a file). It is **project-agnostic**: it tells
   CDK from Next.js by imports (`aws-cdk-lib` vs `next`/`react`) and marker
   files (`cdk.json` / `next.config.*`), finds OpenAPI specs by an
   `openapi:` key rather than an exact filename, and **derives** the
   Context7 framework hints from the imports / `package.json` deps the
   changed files actually use and the codegen hints from the project's
   own Makefile targets — so it adapts to any repo layout, not a fixed one.
   Use the routing it recommends in Phase A sub-agent launches — these
   defaults beat the one-size-fits-all suggestions in §"Execution Strategy"
   below because they pick specialist agents (`cloud-architect` for CDK,
   `frontend-developer` for Next.js, etc.) plus Context7 doc-fetch hints
   for frameworks with fast-moving APIs (StoreKit/Vision/FoundationModels,
   AWS CDK, Next.js App Router).

   For **mixed-language diffs**, the script prints one routing block per
   language. Per block you spawn the bundled Phase A set — ONE mechanical
   bundle agent (Passes 1,3,5,6,7) + ONE Pass 2 specialist — plus ONE
   whole-project FRESHNESS agent for the review overall (a CDK + Go diff =
   2 bundle + 2 Pass 2 + 1 FRESHNESS = 5 launched in a single Agent batch,
   down from 13 in the old per-pass fan-out). **Scope the diff per block:**
   each language's two agents receive ONLY that language's hunks (partition
   the captured diff by the routing-script classification), not the full
   cross-language diff — this halves the duplication penalty on mixed diffs.
   Pass 1's whole-codebase grep is scope-independent, and the parent Pass 8
   plus the whole-project Pass 9 still see the full diff. Each language's
   findings flow into one shared Final Report.

   If the script is missing (older install or non-plugin context), fall
   back to the hardcoded defaults in §"Execution Strategy" — they're
   correct for Go but only adequate for the other languages.

## Pass 1 — STRUCTURAL

Goal: Every removed symbol has zero remaining references in the codebase.

1. Parse the diff for **removed** or **renamed** symbols — functions, types, structs, interfaces, variables, constants, exports.
2. For each removed symbol, grep the entire codebase (excluding `vendor/`, `node_modules/`, `.git/`, `target/`, `build/`, `dist/`, `cdk.out/`, `.next/`, and generated files like `*.generated.*`, `*_pb.go`, `*.pb.go`) for remaining references.
3. Report findings as:
   ```
   STRUCTURAL: <symbol> removed in <file> but still referenced at <file>:<line>
   ```
4. If zero issues found, report "STRUCTURAL: Clean — no dangling references."

> Language-specific grep patterns and language-server escalation guidance: `resources/pass-reference.md` § Pass 1. Paste only the sections for the detected language families into this pass's sub-agent prompt.

## Pass 2 — BEHAVIORAL

Goal: Every behavior change is intentional and safe for existing data.

1. Assess what **behavior** changed in each modified file (not what lines changed — what the code *does* differently now). To keep output crisp, narrate (1 sentence) ONLY files that carry a CRITICAL or HIGH flag below; summarize the rest as a one-line count (e.g. "6 other files: behavior-preserving refactors, no risk flags").
2. Flag as **CRITICAL** if any change could:
   - Corrupt existing database records (wrong defaults, changed attribute types, renamed keys)
   - Break backward compatibility with older clients (removed fields, changed response shapes, modified enums)
   - Alter authentication or authorization logic (changed middleware, modified token validation, permission checks)
   - Change data migration behavior (bulk updates, backfills, schema transformations)
3. Flag as **HIGH** if any change:
   - Modifies error handling in a way that could swallow failures silently
   - Changes sort order, ranking, or scoring logic
   - Alters notification or push behavior
4. Report each finding with the flag and a 1-sentence explanation of the risk.

## Pass 3 — SPEC DRIFT

Goal: Every API-visible change in the diff under review is reflected in the project's spec, generated types, and data model documentation. This catches what pre-commit hooks usually don't: query param drift, response shape drift, and data-model doc staleness. Run this BEFORE tests — no point testing code that violates the contract.

**This pass is convention-based.** Each sub-check looks for common project layouts. If the convention isn't present in the project, mark the sub-check "N/A — project convention not detected" and continue. Do not fail the pass because the project doesn't use the convention.

### 3a. Query Param Drift

1. Scan the diff for new or changed query-param reads in handler files. Patterns to look for:
   - Go: `r.URL.Query().Get("...")`, `mux.Vars(r)["..."]`
   - TypeScript/JS: `req.query.X`, `searchParams.get("...")`, `nextUrl.searchParams.get("...")`
   - Python: `request.args.get("...")`, `request.query_params.get("...")`
2. For each query param name, find the handler's route in the project's routing definition (look for `cmd/*/main.go`, `app/api/**/route.ts`, `routes.py`, etc.).
3. Locate the project's OpenAPI spec (try `api.yaml`, `openapi.yaml`, `openapi/*.yaml`, `docs/api.yaml`, `spec/openapi.yaml`). If found, verify the param appears as an `in: query` parameter on that endpoint.
4. Report: `SPEC DRIFT [query]: param "fresh" used in HandleLeaderboard but not defined in api.yaml GET /groups/{id}/leaderboard`
5. If no OpenAPI spec exists in the project, mark "3a: N/A — no OpenAPI spec detected."

### 3b. Response Shape Drift

1. Scan the diff for new or changed response writes in handler files. Patterns:
   - Go: `writeJSON(...)`, `json.NewEncoder(w).Encode(...)`, `c.JSON(...)`, inline `map[string]any{...}`
   - TypeScript/JS: `res.json(...)`, `NextResponse.json(...)`, `return Response.json(...)`
   - Python: `JsonResponse(...)`, `return jsonify(...)`
2. Identify the top-level keys in the response.
3. If the project has an OpenAPI spec, find the endpoint's response schema (follow `$ref` to resolve).
4. Flag any key present in code but absent from the spec, or any required spec field missing from code.
5. Report: `SPEC DRIFT [response]: key "totalCount" returned by HandleScoreLeaderboard but not in ScoreLeaderboardResponse schema`

### 3c. Request Body Drift

1. Scan the diff for new or changed request body decoding. Patterns:
   - Go: `decodeJSON(r, &...)`, `json.NewDecoder(r.Body).Decode(&...)`
   - TypeScript/JS: `await req.json()`, Zod schemas in route handlers
   - Python: `request.json`, Pydantic models on FastAPI routes
2. Identify the target struct/type. If new fields appear, verify those fields exist in the corresponding `requestBody` schema in the spec.
3. Report: `SPEC DRIFT [request]: field "timezone" decoded in HandleUpdateMe but not in UpdateUserRequest schema`

### 3d. Generated Type Freshness

1. Look for type-generation scripts in the project using the language-specific detection patterns in `pass-reference.md` § Pass 3.
2. If found, run the relevant target/script.
3. Run `git diff` on the generated artifact paths (look for files matching `*.generated.{ts,go,swift,kt}`, `*_gen.*`, `generated/`, `**/types/api.*`).
4. If any generated file has uncommitted changes after regeneration → types are stale.
5. Report: `SPEC DRIFT [types]: <path>/api.generated.ts is stale — regeneration produced changes` or "Generated types are fresh."
6. If no codegen is detected by any pattern in that section, mark "3d: N/A — no codegen detected."

> Codegen detection patterns by language/tool: `resources/pass-reference.md` § Pass 3.

### 3e. Route Parity

1. Look for a route-parity test in the project. Common names: `TestRoutesMatchSpec`, `test_routes_match_spec`, `routes.test.ts`, files with "parity" or "spec match" in the name.
2. If found, run it scoped to the test (e.g., `go test ./... -run TestRoutesMatchSpec -count=1` or the equivalent for the project's test runner).
3. Report pass/fail. If it fails, quote the mismatched routes.
4. If no such test exists, mark "3e: N/A — no route-parity test detected."

### 3f. Data Model / Schema Drift

1. Scan the diff in any database/persistence layer (`db/*.go`, `prisma/schema.prisma`, `models.py`, `migrations/`, etc.) for new key patterns, entity prefixes, table/column additions.
2. Look for data-model documentation in conventional locations: `docs/data-model.md`, `docs/dynamodb-data-model.md`, `docs/database.md`, `docs/schema.md`, `ARCHITECTURE.md`.
3. For each new entity / key pattern / table, verify it's reflected in the docs.
4. Report: `SPEC DRIFT [datamodel]: new key pattern "AUTO_TAUNT#" in db/autotaunt.go but no entry in docs/dynamodb-data-model.md`
5. If no data-model doc exists, mark "3f: N/A — no data-model doc detected."

### 3g. OpenAPI Spec Lint

1. If the project has a CI command for spec validation (`make validate-openapi`, `npm run lint:openapi`, `spectral lint`), run it.
2. If the project has a Go struct ↔ spec validator script (e.g., `scripts/check-go-models.js`), run it.
3. Report errors or "Generated types are fresh."

If zero issues across all sub-checks, report "SPEC DRIFT: Clean — all API changes match the spec (or N/A)."

## Pass 4 — TEST

Goal: Run only the tests that cover modified files. Propose fixes for failures but never apply them.

1. From the list of modified files, identify the corresponding test files:
   - Go: `*_test.go` files in the same package directory
   - TypeScript/JS: co-located `*.test.*` or `*.spec.*` files, or files in `__tests__/`
   - Python: `test_*.py` or `*_test.py` in the same or `tests/` directory
   - Swift: test targets that import the modified module
   - Rust: `#[cfg(test)]` blocks in the same file, or `tests/` integration tests
2. Run only those tests using the project's test runner. Use the per-language scoping commands in `pass-reference.md` § Pass 4 to avoid running the entire suite:

> Test-scoping commands per language: `resources/pass-reference.md` § Pass 4. This pass runs in the parent: Read that section at execution time.



3. If **all tests pass**: report "TEST: All affected tests pass."
4. If **any test fails**:
   - Show the failure output
   - Read the failing test and the code it tests
   - Propose a fix (show the diff) but state clearly: "Proposed fix — NOT applied"
   - NEVER edit the file. NEVER auto-apply.

## Pass 5 — TEST COVERAGE

Goal: Every new or modified behavior has test coverage. Not just "tests pass" (Pass 4) but "tests exist for the changes." A green Pass 4 on zero tests is not a passing review.

1. For each file in the changed files list, locate the corresponding test file(s) using the conventions in Pass 4.
2. For each new or modified exported/public function, handler, or method, check whether any test references it by name.
3. For each new code branch, error case, feature flag, or conditional path, check whether a test exercises it — see `pass-reference.md` § Pass 5 for what "covered" looks like in each language.
4. For bug fixes: verify a **regression test** exists — a test that would have failed before the fix and passes after. For ALL new or modified tests, confirm the test can fail: the assertion depends on the changed code path, is not tautological, and the subject is not mocked away. A test that cannot fail counts as missing coverage.
5. Flag missing coverage:
   - **CRITICAL**: New public API endpoint, HTTP handler, Lambda entry point, or cron entry point with zero tests
   - **HIGH**: New business-logic branch (new error case, new conditional, new feature flag) with no test
   - **HIGH**: Bug fix with no regression test
   - **MEDIUM**: Modified function where existing tests don't cover the new behavior
   - **LOW**: Internal helper with no direct test but covered transitively by caller tests
6. Report: `TEST COVERAGE: handler HandleCreateAutoTaunt has no test in <path>/autotaunt_test.go`

If zero issues, report "TEST COVERAGE: Clean — all changes have corresponding tests."

> What counts as "covered" per language (table-driven tests, it.each, @Test arguments, parametrize): `resources/pass-reference.md` § Pass 5.

## Pass 6 — OBSERVABILITY

Goal: Production issues in this code can be debugged without a repro. Logs, metrics, and error context are sufficient to locate the failure from outside.

1. For each new or modified code path, check for:
   - **Structured logging** at entry/exit of significant operations (slog, logger, console with context keys, log/slog, pino, structlog, etc.)
   - **Error wrapping** — errors carry context up the stack (Go `fmt.Errorf("... %w", err)`, TS `new Error("...", { cause: err })`, Python `raise X from err`), not returned bare
   - **Request/user/correlation identifiers** in logs for traceability (user ID, request ID, trace ID, Lambda request ID)
   - **Key decision points logged** (e.g., "cache hit", "falling back to provider X", "skipping due to feature flag")
   - **Metrics or timings** for rate-limited, queued, retried, or externally-dependent operations
2. Flag gaps:
   - **CRITICAL**: New error path that silently swallows failures (`if err != nil { return nil }`, empty `catch` block, ignored promise rejection, bare `except: pass`)
   - **HIGH**: New handler, background job, or function entry point with no logging — production issues would be invisible
   - **HIGH**: Error returned without wrapping, making root-cause hard to trace from a log entry
   - **HIGH**: PII, credentials, or tokens logged in plain text
   - **MEDIUM**: Slow operation (DB query, external API call, S3 put) with no timing log or metric
   - **MEDIUM**: Removed log lines or metrics in the diff — confirm intent
   - **LOW**: Missing debug-level log on a branch that would aid troubleshooting
3. For Lambda/CloudWatch-deployed code (or equivalent serverless logging targets), confirm logs include enough context to correlate with the triggering request.
4. Report: `OBSERVABILITY: HandleAutoTauntTrigger returns err without wrapping — log stack traces will lack context (db/autotaunt.go:142)`

If zero issues, report "OBSERVABILITY: Clean — new code paths are debuggable."

> Language-specific observability patterns (slog/pino/OSLog/structlog idioms, Lambda logging): `resources/pass-reference.md` § Pass 6.

## Pass 7 — DOCUMENTATION

Goal: Every user-visible, operator-visible, or API-visible change is documented. Stale docs are worse than missing docs.

1. For each change in the diff, determine which docs should reflect it:
   - **README.md** — setup steps, env vars, build/deploy commands, prerequisites
   - **API specs** — `api.yaml` / `openapi.yaml` endpoint, schema, and example updates
   - **Architecture / design docs** — files under `docs/`, ADRs, runbooks
   - **Data model docs** — `docs/data-model.md`, `docs/dynamodb-data-model.md`, or equivalent
   - **Inline doc comments** — godoc on exported Go symbols, TSDoc/JSDoc on exported TS symbols, Swift doc comments on public APIs, Python docstrings — see `pass-reference.md` § Pass 7
   - **CHANGELOG / release notes** — user-facing behavior changes
   - **Infrastructure/runbook docs** — CDK stack diagrams, Terraform docs, deployment runbooks, on-call playbooks
   - **`.env.example`** — any new environment variable
2. For each relevant doc location:
   - If the doc file exists and was updated in the same diff → OK.
   - If the doc file exists but was not touched → read it and flag any section made stale by this change.
   - If the doc file is missing entirely for a surface that warrants one → flag.
3. Flag gaps:
   - **CRITICAL**: Public API change (endpoint added/removed/renamed, signature changed) without matching `api.yaml` / `openapi.yaml` update
   - **HIGH**: New env var, config flag, or required setup step without `.env.example` or README update
   - **HIGH**: Changed behavior contradicts existing doc statements (stale doc — the doc now lies)
   - **HIGH**: New entity, table, or key pattern without data-model doc update
   - **MEDIUM**: New exported function/type/class without doc comment (godoc/jsdoc/Swift doc/docstring)
   - **MEDIUM**: Removed symbol still referenced in docs
   - **LOW**: Minor internal changes where docs could be clearer but are not wrong
4. Report: `DOCUMENTATION: New env var AUTO_TAUNT_LAMBDA_ARN used in cdk/lib/api-stack.ts but missing from .env.example and README setup section`

If zero issues, report "DOCUMENTATION: Clean — all changes are documented."

> Language-specific doc comment conventions (godoc, TSDoc, Swift ///, docstrings): `resources/pass-reference.md` § Pass 7.

## Pass 8 — ADVERSARIAL

Goal: Try to break the changes. Think like a malicious user, a race condition, or production data that doesn't match test assumptions.

For each significant change, probe these angles:

- **Requirements attack**: read the spec/ticket as a hostile lawyer. Do any two rules contradict? Is a stated absolute ("always", "never") revoked by another clause? Does the requested interface conflict with the requested behavior? If the diff silently resolves a spec contradiction, that is a finding (MEDIUM or higher): state the resolution chosen and flag it for the author. A flawless implementation of a broken spec is still broken.
- **Auth/permissions**: What request would produce a 401 or 403 that didn't before? What if the user's token is expired, missing, or from a different provider?
- **Empty/nil data**: What if the input is empty, nil, zero-length, or missing optional fields? What about empty arrays vs null?
- **Production vs test data**: Are there assumptions about data shape that hold in tests but not in production? Old records missing new fields? Records with unexpected enum values?
- **Concurrency**: Could two requests hitting this code simultaneously cause a race condition, double-write, or inconsistent state?
- **Backward compatibility**: Would an older client (that doesn't know about this change) break, crash, or show wrong data?
- **Boundary conditions**: Max values, very long strings, Unicode, special characters, time zones, midnight edge cases?
- **Injection / untrusted input**: SQL/NoSQL injection, command injection, XSS, path traversal, SSRF in any new code path that consumes user input?

> Language-specific gotchas (Go nil maps/goroutine leaks, TS hydration/undefined-vs-null/as-assertions, Swift IUO/Sendable/actor reentrancy, Python mutable defaults/async exceptions): `resources/pass-reference.md` § Pass 8. This pass runs in the parent: Read that section at execution time.



Rate each finding:
- **CRITICAL**: Will cause data loss, security bypass, or crash in production
- **HIGH**: Likely to cause user-visible bugs under realistic conditions
- **MEDIUM**: Edge case that could bite someone eventually
- **LOW**: Theoretical concern, unlikely but worth noting

## Pass 9 — FRESHNESS

Goal: Every direct dependency, framework, and language runtime is current enough to be safe, carries no known CVE and no end-of-life runtime, and each staleness call separates an overdue or security-driven upgrade from one that is still too early to take.

Unlike the other passes, Pass 9 is a WHOLE-PROJECT audit. It runs on every chad-review regardless of what the diff touches. It reads the changed-files list only to prioritize and to tag dependencies the current change touched, never to gate whether the pass runs.

0. **Cache check.** Cache file: `~/.claude/chad-review-cache/<sha256 of git remote get-url origin>.json` (home-dir keyed by origin URL so all worktrees of a repo share it and nothing touches the repo). Schema: `{ generatedAt, manifests: {<repo-relative path>: <sha256 of content>}, manifestSet: [sorted paths], table: <markdown table verbatim>, severityLines: [...], scannerUsed, lastLocalScanClean }`.
   - Run manifest discovery (step 1's glob with the prune list) and hash each discovered manifest AND its lockfile.
   - **FULL RUN** (steps 1-5 as written, then write the cache) if ANY: cache file missing or unparseable; discovered manifest set differs from cached `manifestSet`; any hash differs; `generatedAt` older than 7 days; diff shape is `deps-only` or the diff touches any manifest.
   - **CACHE HIT** otherwise: do NOT launch the FRESHNESS sub-agent and do NOT call context7/WebSearch. In the parent, re-run ONLY the local CVE scan (`osv-scanner -r .` or the ecosystem scanner: it is local, cheap, and preserves same-day detection of newly published CVEs against unchanged deps). If the scan is clean, report the cached table under Pass 9 with the header "FRESHNESS (cached <date>, manifests unchanged; local CVE scan re-run this review: clean)". If the scan finds anything new, invalidate the cache and do a FULL RUN. The 7-day TTL is safe because the security signal is never delayed; the only cached intelligence is latest-version/maturity data, whose consumers are the 60-90-day HOLD/UPGRADE windows.
1. **Manifest discovery.** Find every dependency manifest in the project, pruning `vendor/`, `node_modules/`, `.git/`, `target/`, `build/`, `dist/`, `.next/`, `cdk.out/`, `DerivedData/`, `Pods/`. Use the ecosystem table below. If no recognized manifest exists, report N/A and stop. Read each manifest and extract DIRECT dependencies plus the runtime constraint (`go` directive, `engines.node`, `environment: sdk`, `swift-tools-version`, `requires-python`, `rust-version`). Skip transitive deps for version resolution; step 3 still scans them for CVEs.
2. **Version resolution via context7.** For each direct dependency, read the pinned or current version from the manifest or lockfile, then resolve the latest version and migration intelligence from context7 (`resolve-library-id`, then `query-docs` with a topic like "latest version, migration guide, breaking changes"). Capture the three things context7 is good at: latest version, whether a migration guide exists, and how large the breaking surface is (count of breaking changes, codemods required). context7 is weak on exact release DATES: where you need release recency or patch-count and context7 does not surface it, fall back to a lightweight WebSearch ("<lib> <version> release date") purely to gauge recency. context7 stays the primary source. Soft-cap the number of context7 lookups (about 12 to 15), prioritizing runtimes, core frameworks, security-relevant deps, and diff-touched deps; list anything beyond the cap as "not individually version-checked this run."
3. **Security and EOL check.** Run the ecosystem's CVE scanner (govulncheck, npm/pnpm audit, pip-audit, cargo audit, `dart pub outdated --mode=security`) or the language-agnostic `osv-scanner -r .` over the lockfiles. If no scanner is installed, say so ("security scan unavailable: install osv-scanner/govulncheck") rather than reporting clean. Cross-reference the runtime against end-of-life data (endoflife.date for Node, Python, Go; the framework's own support window for majors). A current version with a known CVE, or a runtime or framework major past support, is CRITICAL and OVERRIDES any "too early" hold from step 4.
4. **Upgrade-timing judgment.** For each stale dependency, apply the heuristic below to decide UPGRADE (overdue or mature) versus HOLD (too early). This judgment is the point of the pass.
5. **Report.** Emit the recommendation table, then list CRITICAL and HIGH findings as severity lines.

### Upgrade-timing heuristic

Recommend **HOLD (too early to upgrade, non-blocking)** when ALL hold:
- the gap is a MAJOR bump, and
- the latest major shipped recently (roughly under 60 to 90 days, judged via the WebSearch recency probe), and
- context7 shows a substantial breaking surface (a migration guide with many breaking changes, or required codemods), and
- the new major has few patch releases so far (still x.0.0 or x.0.1, fewer than about 3 patches).

Recommend **UPGRADE** when ANY hold:
- **Security/EOL override:** the current version has a known CVE, or the current runtime or framework major is end-of-life or out of support. CRITICAL, "upgrade now", overrides any HOLD.
- the latest is MATURE: shipped more than about 90 days ago, reached x.2 or x.3 with several patches.
- the gap is only MINOR or PATCH with no breaking surface.
- the current major is itself losing support soon, making the upgrade overdue even if the new major is recent.

**Pre-1.0 (0.x) caution:** under semver, a 0.y to 0.(y+1) MINOR bump is breaking, so treat it as major-equivalent and apply the same recency and patch-count caution. A brand-new 0.x minor with no follow-up patches is a HOLD.

### Severity mapping for this pass

Severity reflects RISK; the **disposition** (do-now / schedule / hold / backlog) is the more important output. Outdated frameworks are a finding to ACTION, not debt to launder into a backlog nobody reads — keeping dependencies current is continuous maintenance, and every safe upgrade you defer compounds into a riskier big-bang migration later. That is the whole reason this pass exists.

- **CRITICAL**: current version has a known CVE, or the runtime or framework major is end-of-life or unsupported. Recommendation: UPGRADE NOW. Overrides any HOLD.
- **HIGH**: a core framework or runtime is one or more majors behind AND the current major is in its support sunset, window closing, even without a CVE yet.
- **MEDIUM**: a core framework or important direct dependency is meaningfully behind (a major behind, OR several minors, OR years stale) and the upgrade is SAFE — the target is mature and there is no breaking HOLD. This is the bread-and-butter finding of the pass; it is **do-now**, not "someday".
- **LOW**: a single patch behind with no accumulation, on a non-core dependency. Reserve LOW for genuinely trivial lag — a *stack* of "only a minor/patch behind" deps is NOT trivial in aggregate; surface the batch.
- **HOLD** is a recommendation, not a severity. Non-blocking, "too early to upgrade" (a brand-new breaking major). Attach a revisit signal ("after x.2" or "+90d").

**Disposition — decide one per flagged dependency (this is the point of the pass):**
- **UPGRADE NOW (safe)** — the DEFAULT for any HIGH/MEDIUM whose target is mature and not under a breaking HOLD (most stale frameworks land here). Do **not** file it to the backlog. Surface it prominently, recommend doing it in this change or an immediate fast-follow, and **offer to perform it** (bump → build → run the affected test/integration suite). If you catch yourself sending a mature, safe framework upgrade to the backlog, re-classify it as UPGRADE NOW.
- **SCHEDULE** — a CRITICAL/EOL the diff did not touch and can't be done safely inside this commit → a required, dated follow-up, never silent backlog.
- **HOLD** — a brand-new breaking major; the only disposition that genuinely means "wait", with a revisit signal.
- **BACKLOG** — reserved for LOW trivial lag only.

### Report format

One row per direct dependency that is behind or flagged (current-and-clean deps summarized as a closing count, not listed):

| Dependency | Current | Latest | Δ behind | Maturity / Released | Security | Recommendation |
|---|---|---|---|---|---|---|
| next | 14.2.30 | 15.0.1 | 1 major | shipped ~3 wks ago, 1 patch, large App Router migration | clean | HOLD (too early; revisit after 15.2 or +90d) |
| react | 18.3.1 | 19.1.0 | 1 major | mature: ~9 mo ago, at 19.1.x, modest migration | clean | UPGRADE NOW (safe), MEDIUM |
| mark3labs/mcp-go | v0.46.0 | v0.55.1 | 9 pre-1.0 minors | mature line, no migration guide needed | clean | UPGRADE NOW (safe), MEDIUM — bump + re-run the integration suite |
| typescript (dev) | 4.9.3 | 5.9.3 (5.x) | 1 major behind; 6.0 exists but is days old | 5.x mature; 6.0 brand-new = HOLD | clean | UPGRADE NOW (safe) to 5.9.3; HOLD 6.0 |
| golang.org/x/net | v0.21.0 | v0.38.0 | several minors | n/a | CVE reachable per govulncheck | UPGRADE NOW, CRITICAL (overrides hold) |
| some_dart_pkg | 0.8.1 | 0.9.0 | 0.x minor = major-equiv | shipped ~2 wks ago, 0 patches | clean | HOLD (0.x churn, brand-new) |
| node (runtime) | 18.x | 22.x LTS | runtime, 18 EOL 2025-04-30 | n/a | EOL | UPGRADE NOW, CRITICAL (EOL) |

Then list CRITICAL and HIGH findings AND every **UPGRADE NOW (safe)** finding as severity lines (safe upgrades are the headline value of this pass — do not bury them), for example:
- `FRESHNESS [security]: golang.org/x/net v0.21.0 is affected by a known CVE (reachable per govulncheck); upgrade to v0.38.0.`
- `FRESHNESS [eol]: Node 18 runtime reached end-of-life 2025-04-30; upgrade to 22 LTS.`
- `FRESHNESS [upgrade-now]: mark3labs/mcp-go is 9 pre-1.0 minors behind (v0.46.0 → v0.55.1), target is mature and clean; bump now and re-run the MCP integration suite. Safe, recommended this change.`
- `FRESHNESS [hold]: next 15.0.1 shipped ~3 weeks ago with a large migration surface; hold at 14.2.x, revisit after 15.2.`

Tag any dependency the current diff touched with `(diff-touched)`.

If zero issues, report "FRESHNESS: Clean. All direct dependencies are current or within a safe lag, no CVE and no end-of-life runtime." If no manifest is recognized, report "FRESHNESS: N/A — no recognized manifest detected."

> Ecosystem-specific manifest, version, and security sources (Go/Node/Dart/Swift/Python/Rust): `resources/pass-reference.md` § Pass 9.

## Performance Budget

Target: under ~2 minutes wall-clock for a typical single-language PR (5-10 file changes) with a warm freshness cache; non-standard diff shapes (docs-only, config-only, tiny) should finish well under a minute. The bundled Phase A fan-out is one lever — three sub-agents (mechanical bundle + Pass 2 + FRESHNESS) running concurrently means the wall-clock time is dominated by the slowest single agent, not the sum. The diff-shape matrix (Pre-flight step 5) and the freshness cache (Pass 9 step 0) are the bigger levers: most runs launch just those few agents and zero network version lookups.

If the review is running long, cut in this order:

1. **Pass 9 (FRESHNESS)**: the cache (step 0) is the primary lever — a warm cache removes the entire network-bound version-resolution loop. On a forced full run, the context7 loop is the first thing to cap when the review runs long. Reduce the soft-cap, or resolve versions only for runtimes and core frameworks. NEVER skip the local security and EOL scan (`osv-scanner` / `govulncheck` / `pip-audit`): a CVE or EOL runtime is CRITICAL and the scan is cheap.
2. **Pass 3 (SPEC DRIFT)**: sub-checks 3d and 3g (type regeneration and spec lint) are the most expensive because they compile or invoke external tools. If the diff has no handler changes, mark 3a–3c N/A immediately without running the generators.
3. **Pass 4 (TEST)**: if the project's test suite is slow (full compile + integration tests), scope to `-run TestFunctionName` rather than `./...`. Only run the packages that contain changed files.
4. **Pass 1 (STRUCTURAL)**: on diffs with many removed symbols, grep can be slow on large codebases. Scope grep to `--include="*.go"` / `--include="*.ts"` rather than all file types; skip `vendor/` and `node_modules/` aggressively.
5. **Phase B / Phase C (TEST + ADVERSARIAL)**: Pass 4 runs in the parent; Pass 8 runs inline in the parent on opus/sonnet sessions (a Fable session delegates it to a JUDGE sub-agent after Phase A). When Pass 8 is inline and the Phase A sub-agents are still running, proceed to its adversarial reasoning (no tool calls needed) so it's ready to report when Phase A completes.

Never skip a pass to meet the time budget. Mark slow passes with a note ("3d skipped — codegen takes > 30s; run manually with `make generate-types` and check `git diff`") rather than silently omitting them.

## When to Use chad-review vs Other Review Skills

**Use `chad-review`** (this skill) when:
- You are about to commit or push and want a rigorous pre-commit gate
- The changes touch multiple layers (e.g., Go handler + CDK + TypeScript frontend) and you want all 9 passes run with parallel sub-agents
- You want a structured NO-GO / CONDITIONAL / GO verdict with a ready-to-use fix prompt
- You want language-specific coverage analysis (table-driven tests, it.each, parametrize)

**Use `/review` (Claude Code built-in)** when:
- You want a quick read of a single file or a small change (< 3 files)
- You don't need the 9-pass structure — just a second pair of eyes
- You're in a fast iteration loop and a full 9-pass review would break your flow

**Use `pr-review-toolkit:review-pr` (marketplace skill)** when:
- The code is already in a pull request on GitHub and you want PR-centric review (diff comments, reviewer context, CI status)
- You want review feedback formatted as inline PR comments rather than a terminal report
- The PR has been open long enough that it includes discussion context worth incorporating into the review

Rule of thumb: **chad-review is for before the commit; pr-review-toolkit is for after the PR is open.**

## Final Report

After all 9 passes, output a single consolidated report:

```
## Chad Review — Report
Diff shape: <shape>

### Pass 1 — STRUCTURAL
[findings or "Clean"]

### Pass 2 — BEHAVIORAL
[behavior changes + flagged risks]

### Pass 3 — SPEC DRIFT
[findings per sub-check or "Clean"/"N/A"]

### Pass 4 — TEST
[test results + any proposed fixes]

### Pass 5 — TEST COVERAGE
[missing tests with severity or "Clean"]

### Pass 6 — OBSERVABILITY
[logging/error/metric gaps with severity or "Clean"]

### Pass 7 — DOCUMENTATION
[doc gaps with severity or "Clean"]

### Pass 8 — ADVERSARIAL
[findings with severity ratings]

### Pass 9 — FRESHNESS
[dependency currency table + CVE/EOL findings with severity, or "Clean"/"N/A"]

### Verdict: [GO / NO-GO / CONDITIONAL]
[1-2 sentence summary of whether to commit as-is, fix something first, or stop and rethink]
```

Each sub-agent pass section ends with its self-refutation tally line (`Self-refutation: X raised, Y refuted, Z reported`); refuted CRITICALs stay visible as "raised then refuted: <evidence>" so the parent can double-check them. When assembling the report, carry the sub-agents' finding lines and tallies verbatim but **strip any process narration** an agent emitted despite the output contract (methodology, "I checked…", restated diff) — findings in the deliverable, never the process.

**How Pass 9 affects the verdict.** Because Pass 9 is whole-project and always-on, a pre-existing dependency issue unrelated to the diff should not hard-block an unrelated commit:

- **CRITICAL (CVE or EOL) on a dependency the diff touched or introduced → NO-GO.** The change is adjacent to a known-vulnerable or end-of-life dependency; fix before committing.
- **CRITICAL (CVE or EOL) that is pre-existing and NOT touched by the diff → CONDITIONAL**, with a prominent callout: the current change is safe to commit, but the project carries a CRITICAL dependency issue that must be scheduled now.
- **HIGH (sunsetting major) → CONDITIONAL** if urgent, otherwise advisory with a recommendation to schedule.
- **MEDIUM safe-upgrade findings (UPGRADE NOW) → never silently backlogged.** A GO stays a GO (a safe upgrade rarely needs to block a commit), but the report MUST surface these prominently and the post-report Fix Prompt MUST list them as recommended actions with a verify step — and you should OFFER to perform them in this change or an immediate fast-follow. Defaulting a mature framework upgrade to the backlog is the failure mode this pass exists to prevent.
- **HOLD, and genuinely-trivial single-patch LOW lag → advisory only, never blocks.** These appear in the report; only these feed the BACKLOG.

## After the Report — Fix Prompt

If the verdict is NO-GO or CONDITIONAL — **or** if Pass 9 produced any **UPGRADE NOW (safe)** framework/dependency findings even on a GO — offer to generate a **fix prompt** the user can use to kick off a planning session. The fix prompt must:

1. **List every finding that needs action** — include the pass, severity, file path, and line numbers.
2. **Describe what each fix should accomplish** — not the implementation, but the outcome (e.g., "ghost.go should use Eastern time for the race date, matching how live races work").
3. **Reference existing patterns** — point to code that already does the right thing in the codebase.
4. **Separate blocking fixes from the rest — but fix all of them** — CRITICAL and HIGH block this commit; MEDIUM and LOW are fixed in the same change (or an immediate fast-follow), never deferred to a backlog. Every finding gets actioned; the split is only about what blocks the merge, not about what is worth fixing. One exception: a Pass 9 FRESHNESS CRITICAL that the diff did not touch (a pre-existing CVE or end-of-life runtime) is a required follow-up to schedule now, not a blocker for this specific commit. List it under required fixes but label it "schedule now, does not block this commit", consistent with the CONDITIONAL verdict rule.
5. **Add a "Recommended — safe to do now" section for Pass 9 UPGRADE NOW (safe) findings** — every mature, non-breaking framework/dependency upgrade gets a line with its concrete bump (`current → target`) and a verify step (the build plus the test/integration suite that exercises it). These are not commit blockers, but they are the headline value of the freshness pass, so they get their own heading — never folded into "optional polish" and never dropped to the backlog. Explicitly **offer to perform them now** (in this change or an immediate fast-follow) rather than just listing them. Keep HOLD items out of this section (they carry a revisit signal instead).
6. **End with a verification step** — "After fixing, run `/chad-review` again to confirm all issues are resolved."

Present the prompt in a copyable code block. Then:

- Ask "Want me to enter plan mode with this prompt, or do you want to edit it first?" ONLY when BOTH hold: the verdict is NO-GO or CONDITIONAL, AND this is a direct interactive session with the user. If **enter plan mode**: enter plan mode with the fix prompt as the task. If **edit first**: wait for the user's edit, then enter plan mode with the edited version.
- On a GO verdict, print the report (including any "Recommended — safe to do now" section) and end the turn without asking.
- When running as a subagent, inside another skill (e.g. /wrapup), or in any headless/autonomous invocation, never block on a question: the full fix prompt is already in the report body; return and let the caller act on the verdict.

## Execution Strategy

**Delegate passes to sub-agents in parallel.** Passes that only read the diff are self-contained and can run concurrently via the Agent tool. Single-message multi-tool-use batches the launches in parallel.

### Model Tiering (session-relative)

**ALWAYS pass an explicit `model` on every Agent launch** — computed from the session model, not hardcoded. This is load-bearing: since Claude Code v2.1.198 an Agent/`Explore` launch with NO explicit `model` inherits the *parent* (session) model, so an omitted model silently rides the parent tier. Do not soften this "ALWAYS" without understanding that.

Two tiers, both derived from the session model **M** (read your own model from environment/system context during pre-flight):
- **MECH** — the rote, rubric-driven passes: **1 STRUCTURAL, 3 SPEC DRIFT, 5 TEST COVERAGE, 6 OBSERVABILITY, 7 DOCUMENTATION, 9 FRESHNESS**, plus the parent's own orchestration.
- **JUDGE** — the merge-gating judgment passes: **2 BEHAVIORAL, 8 ADVERSARIAL, and CRITICAL re-verification**.

| Session **M** | Parent turn | MECH (1,3,5,6,7,9) | JUDGE (2, 8, CRITICAL re-verify) |
|---|---|---|---|
| **opus** | opus | **sonnet** | **opus** |
| **sonnet** | sonnet | sonnet | **sonnet** (trusted for judgment; no escalation) |
| **fable** | fable | **opus** | **opus** |
| unknown / haiku / other | = M | **sonnet** (floor) | **opus** |

Reading: an opus session keeps judgment on opus and drops the rote passes to sonnet; a sonnet session stays sonnet everywhere; a **Fable session keeps only the cheap orchestration shell on Fable and escalates every real review pass to opus** — the quality floor wins for that unusual case, so a Fable-session review costs about like an opus review by design. **Never haiku for any pass** — sonnet is the review floor.

**CRITICAL-escalation re-verification** runs at the JUDGE tier: if a MECH pass reports any CRITICAL, or says it could not confidently classify something, that specific finding is re-verified before it enters the verdict — inline in the parent when the parent is already at the JUDGE tier (opus/sonnet sessions), else folded into the dedicated JUDGE (opus) Pass 8 agent (see Phase C).

### Phase A — bundled sub-agents in parallel (single Agent call batch)

Per language block the routing script emits, launch exactly **two** sub-agents, plus **one** whole-project FRESHNESS agent for the review overall — all in ONE message (single-language diff = **3** Agent tool uses; a CDK + Go diff = 2 bundle + 2 Pass 2 + 1 FRESHNESS = **5**):

**1. Mechanical bundle agent — Passes 1, 3, 5, 6, 7 → `general-purpose`, MECH tier.** One agent owns all five rote passes for the block (`general-purpose` because Pass 3 must run generators / spec validators / route-parity tests, not just grep). It reads the diff ONCE and emits **each pass as its own labeled section** (`## Pass 1 — STRUCTURAL`, etc.), findings-or-`Clean` per the output contract, then ONE combined self-refutation tally. Preserving the five distinct headings is what keeps the 9-heading report invariant intact.

**2. Pass 2 BEHAVIORAL → the language specialist, JUDGE tier.** The one pass whose domain knowledge earns a heavyweight specialist (see picks below). For **CDK**, the `cloud-architect` Pass 2 brief ALSO sanity-checks IaC observability (log retention, X-Ray, alarms) since it already reads the CDK diff — this recovers the one specialist signal the bundle would otherwise dilute; the CDK bundle agent still runs Pass 6 for non-IaC-specific gaps.

Each sub-agent gets: the relevant diff (for a single-language diff, the whole diff inline; for a **mixed-language** diff, ONLY this block's hunks per Pre-flight step 6); the changed-files list; a self-contained brief repeating project context it needs (the sub-agent cannot see the parent conversation); the strict output contract (see "Writing sub-agent prompts"); and an explicit **`model`** computed from §"Model Tiering" (MECH for the bundle, JUDGE for Pass 2).

**3. Pass 9 FRESHNESS is whole-project → `general-purpose`, MECH tier.** Launch it ONCE per review, not per language block, added to the same batch no matter how many blocks the script emits. Its brief:
- The dependency manifests discovered project-wide (or instruct it to discover them with the prune list in Pass 9).
- The changed files list, used ONLY to prioritize and tag `(diff-touched)` deps. State explicitly that the audit is whole-project and does not depend on the diff.
- context7 as the primary source for latest version and migration intelligence; a lightweight WebSearch only as a release-recency probe.
- Output: the recommendation table plus CRITICAL/HIGH/UPGRADE-NOW severity lines (per the Pass 9 report format), under about 350 words.
- read-only, never edit or commit.

**Preferred path: use `chad-review-route.sh` output** (see Pre-flight step 6) — it prints the mechanical-bundle row plus the right Pass 2 specialist and Context7 hints per language family.

**Fallback picks** when the routing script is unavailable:
- **Mechanical bundle (Passes 1,3,5,6,7)** → `general-purpose` at MECH tier, for every language. Fast grep + checklist + generator work; the lean built-in avoids the heavyweight-specialist system-prompt overhead that rote passes don't need.
- **Pass 2 BEHAVIORAL** → the language specialist at JUDGE tier: **Go** `feature-dev:code-reviewer`; **CDK TypeScript** `cloud-architect` (+ IaC observability, Context7 `aws-cdk-lib`); **Next.js / React** `frontend-developer` (Context7 from `package.json`: `next`, `react`, `@tanstack/react-query`, `next-auth`, …); **generic TypeScript / JS** `typescript-pro` (Context7 from imported deps); **iOS Swift** `code-reviewer` (Context7 `swift` + the Apple frameworks the diff imports, per the script). If none matches, `general-purpose`.

Wait for all Phase A sub-agent results (the per-language bundle + Pass 2 agents plus the single FRESHNESS agent) before proceeding.

### Phase B — Pass 4 (TEST) in the parent turn

Do not delegate tests. Run `go test` / `npx vitest` / `pytest` / etc. directly in the parent so test output streams to the user. Tests may reveal failures that need immediate follow-up, and the parent has the full context to propose fixes.

### Phase C — Pass 8 (ADVERSARIAL) at the JUDGE tier

Pass 8 is informed by *everything* the prior passes found, and it plus CRITICAL-escalation re-verification run at the **JUDGE tier**. Its execution mode depends on whether the parent is already at that tier:

- **Parent already at the JUDGE tier (opus & sonnet sessions) → run Pass 8 INLINE in the parent.** The parent holds all prior-pass context; running inline avoids re-reading the diff or losing findings. Run adversarial probes inline with any targeted tool calls (grep, file reads) needed to confirm edge cases.
- **Parent below the JUDGE tier (Fable / unknown sessions) → delegate Pass 8 to a dedicated JUDGE (opus) sub-agent** after Phase A completes. Feed it the full diff plus each prior pass's capped self-refutation digest (the findings + tallies, not raw scratch) so it inherits what it needs; have it also perform the CRITICAL-escalation re-verification for any MECH-pass CRITICALs.

Either way, apply the same self-refutation discipline required of the sub-agents before any Pass 8 finding enters the report.

### Writing sub-agent prompts

Each sub-agent prompt MUST be self-contained:
- State the goal in one sentence (for the bundle agent: name the five passes it owns).
- Include the diff (sub-agents cannot see your conversation): the full diff for a single-language review, or ONLY this language block's hunks for a mixed-language review (Pre-flight step 6).
- Read `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pass-reference.md` ONCE during prompt assembly and paste ONLY the section(s) for the pass(es) this agent owns and the language families the routing script detected — for the bundle agent that is the §Pass 1/3/5/6/7 sections for its language, pasted once. This step is mandatory: skipping it silently degrades sub-agent quality.
- Name the project's specific spec files / validation commands / test harness / doc locations (detect these during pre-flight; if not found, tell the sub-agent the convention is absent and to mark sub-checks N/A).
- Include the strict output contract below (it replaces any word budget).
- Remind them: read-only, never edit or commit.

**Strict output contract (paste verbatim into every sub-agent prompt).** This keeps sub-agent output — and the parent's cost to ingest it — minimal, and enforces "findings in the deliverable, never the process":

```
Output — STRICT, no exceptions:
- Zero preamble, zero restated diff, zero methodology narration.
- One line per finding: SEVERITY | file:line | <=15-word finding
- A pass with no findings outputs exactly: Clean
- A refuted CRITICAL stays visible: SEVERITY | file:line | finding [refuted: <=10-word evidence]
- End with exactly: Self-refutation: X raised, Y refuted, Z reported
(Bundle agent: emit one "## Pass N — NAME" heading per owned pass with its
 finding lines or "Clean" underneath, then ONE combined Self-refutation line.)
(Pass 9: emit the recommendation table (that is data), then its severity/
 UPGRADE-NOW lines as TAG | dep | <=15-word rec, then the tally.)
```

Example sub-agent prompt skeleton:

```
You are running Pass <N> of a pre-commit review on the <project> repo.

Goal: <one sentence>

The diff under review (captured from `git diff HEAD` + untracked files):
<paste diff>

Project-specific context (detected during pre-flight):
- OpenAPI spec: <path or "not present">
- Type-generation script: <command or "not present">
- Route-parity test: <command or "not present">
- Data-model doc: <path or "not present">

Your job:
<numbered steps specific to this pass>

Before reporting, attempt to refute every finding you raised: re-read the surrounding code and check the classic false-positive causes (grep hit inside a comment, string literal, test fixture, or generated file; a "missing test" actually covered by a differently named or integration test; a "stale doc" statement that still holds; a behavior change explicitly intended per an adjacent comment or the commit message). A finding may be dropped ONLY on concrete evidence (a file:line that disproves it), never on plausibility. Refuted CRITICALs are not deleted: report them per the contract.

<paste the strict output contract here>. Read-only — do not edit files or run commits.
```

Example Agent tool call (model is REQUIRED — the value comes from §"Model Tiering" for the current session; the bundle rides MECH, Pass 2 rides JUDGE):

```json
{
  "description": "Mechanical bundle (Passes 1,3,5,6,7)",
  "subagent_type": "general-purpose",
  "model": "<MECH tier for this session — e.g. sonnet on an opus session, opus on a fable session>",
  "prompt": "<self-contained prompt as above>"
}
```

## Rules

- NEVER edit any source file
- NEVER commit anything
- NEVER apply proposed fixes — only show them
- NEVER silently skip a pass: all 9 passes appear as headings in every Final Report. A pass may return early per the diff-shape matrix (Pre-flight step 5), but only with the explicit line "N/A — not applicable to this diff shape (<shape>)", never by omission
- ALWAYS pass an explicit `model` on every Agent launch, computed from the session model per §"Model Tiering" (MECH for the bundle + Pass 9; JUDGE for Pass 2 + Pass 8); never haiku. The explicit model is load-bearing — an omitted one silently inherits the parent/session tier (since Claude Code v2.1.198).
- Pass 3 may run type generators, spec validators, and route-parity tests — these are non-destructive
- If the diff is enormous (50+ files), ask the user if they want to scope the review to specific directories
- If the project's conventions don't match any of the sub-check patterns, mark "N/A" and continue — don't fail the pass
