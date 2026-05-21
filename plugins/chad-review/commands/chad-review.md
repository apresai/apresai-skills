---
name: chad-review
description: 8-pass autonomous pre-commit code review. Use when the user wants to review their changes before committing, asks for a pre-commit review, says "review before I commit" or "review the last commit", or invokes /chad-review. Reviews uncommitted working-tree changes (staged, unstaged, and untracked) if any exist; otherwise falls back to the last commit. Runs structural, behavioral, spec-drift, test, test-coverage, observability, documentation, and adversarial analysis.
---

# Chad Review — 8-Pass Code Review

Autonomous review of uncommitted working-tree changes — or the last commit if the tree is clean. Read-only except for running tests and type regeneration. Never edit source files, never commit.

This skill is project-agnostic. It detects the language and framework of the changes under review and adapts. For project-specific spec/contract checks, it relies on conventions (OpenAPI spec at `api.yaml` or `openapi.yaml`, generated type artifacts at conventional paths, route-parity tests if they exist). When a convention doesn't match the current project, the corresponding sub-check is reported as "N/A — project convention not detected" rather than failing.

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
3. Announce the target to the user in one line, e.g.:
   - `Chad Review — reviewing working tree (2 staged, 3 unstaged, 1 untracked)`
   - `Chad Review — reviewing last commit a1b2c3d "Fix credit refund race"`
4. The captured diff is the input for all 8 passes. The changed files list drives Pass 4 test selection and Pass 5 coverage selection.

## Pass 1 — STRUCTURAL

Goal: Every removed symbol has zero remaining references in the codebase.

1. Parse the diff for **removed** or **renamed** symbols — functions, types, structs, interfaces, variables, constants, exports.
2. For each removed symbol, grep the entire codebase (excluding `vendor/`, `node_modules/`, `.git/`, `target/`, `build/`, `dist/`, `cdk.out/`, `.next/`, and generated files like `*.generated.*`, `*_pb.go`, `*.pb.go`) for remaining references.
3. Report findings as:
   ```
   STRUCTURAL: <symbol> removed in <file> but still referenced at <file>:<line>
   ```
4. If zero issues found, report "STRUCTURAL: Clean — no dangling references."

## Pass 2 — BEHAVIORAL

Goal: Every behavior change is intentional and safe for existing data.

1. For each modified file, explain in 1-2 sentences what **behavior** changed (not what lines changed — what the code *does* differently now).
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

1. Look for type-generation scripts in the project:
   - Makefile targets containing `generate-types`, `gen-types`, `types`, `openapi`
   - npm scripts in `package.json` containing `generate`, `openapi`, `codegen`
   - Standalone scripts like `scripts/generate-*.{js,ts,sh}`
2. If found, run the relevant target/script. Common patterns to try in order:
   - `make generate-types` (if Makefile has the target)
   - `npm run generate` / `pnpm generate` (if package.json has it)
   - `npx openapi-typescript` (if there's a tsconfig + openapi.yaml)
3. Run `git diff` on the generated artifact paths (look for files matching `*.generated.{ts,go,swift,kt}`, `*_gen.*`, `generated/`, `**/types/api.*`).
4. If any generated file has uncommitted changes after regeneration → types are stale.
5. Report: `SPEC DRIFT [types]: <path>/api.generated.ts is stale — regeneration produced changes` or "Generated types are fresh."
6. If no type-generation script is detected, mark "3d: N/A — no codegen detected."

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
2. Run only those tests using the project's test runner:
   - Go: `go test ./path/to/package/...` for each affected package
   - TypeScript: `npx vitest run path/to/test`, `npm test -- --testPathPattern=<pattern>`, or `pnpm test <path>`
   - Python: `pytest path/to/test_file.py` or `python -m unittest <module>`
   - Swift: `xcodebuild test -scheme <scheme> -only-testing:<TestTarget>/<TestClass>`
   - Rust: `cargo test --package <pkg> <pattern>`
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
3. For each new code branch, error case, feature flag, or conditional path, check whether a test exercises it. Look for table-driven test cases, `t.Run` subtests, `describe`/`it` blocks, parameterized tests.
4. For bug fixes: verify a **regression test** exists — a test that would have failed before the fix and passes after.
5. Flag missing coverage:
   - **CRITICAL**: New public API endpoint, HTTP handler, Lambda entry point, or cron entry point with zero tests
   - **HIGH**: New business-logic branch (new error case, new conditional, new feature flag) with no test
   - **HIGH**: Bug fix with no regression test
   - **MEDIUM**: Modified function where existing tests don't cover the new behavior
   - **LOW**: Internal helper with no direct test but covered transitively by caller tests
6. Report: `TEST COVERAGE: handler HandleCreateAutoTaunt has no test in <path>/autotaunt_test.go`

If zero issues, report "TEST COVERAGE: Clean — all changes have corresponding tests."

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

## Pass 7 — DOCUMENTATION

Goal: Every user-visible, operator-visible, or API-visible change is documented. Stale docs are worse than missing docs.

1. For each change in the diff, determine which docs should reflect it:
   - **README.md** — setup steps, env vars, build/deploy commands, prerequisites
   - **API specs** — `api.yaml` / `openapi.yaml` endpoint, schema, and example updates
   - **Architecture / design docs** — files under `docs/`, ADRs, runbooks
   - **Data model docs** — `docs/data-model.md`, `docs/dynamodb-data-model.md`, or equivalent
   - **Inline doc comments** — godoc on exported Go symbols, jsdoc/tsdoc on exported TS symbols, Swift doc comments on public APIs, Python docstrings
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

## Pass 8 — ADVERSARIAL

Goal: Try to break the changes. Think like a malicious user, a race condition, or production data that doesn't match test assumptions.

For each significant change, probe these angles:

- **Auth/permissions**: What request would produce a 401 or 403 that didn't before? What if the user's token is expired, missing, or from a different provider?
- **Empty/nil data**: What if the input is empty, nil, zero-length, or missing optional fields? What about empty arrays vs null?
- **Production vs test data**: Are there assumptions about data shape that hold in tests but not in production? Old records missing new fields? Records with unexpected enum values?
- **Concurrency**: Could two requests hitting this code simultaneously cause a race condition, double-write, or inconsistent state?
- **Backward compatibility**: Would an older client (that doesn't know about this change) break, crash, or show wrong data?
- **Boundary conditions**: Max values, very long strings, Unicode, special characters, time zones, midnight edge cases?
- **Injection / untrusted input**: SQL/NoSQL injection, command injection, XSS, path traversal, SSRF in any new code path that consumes user input?

Rate each finding:
- **CRITICAL**: Will cause data loss, security bypass, or crash in production
- **HIGH**: Likely to cause user-visible bugs under realistic conditions
- **MEDIUM**: Edge case that could bite someone eventually
- **LOW**: Theoretical concern, unlikely but worth noting

## Final Report

After all 8 passes, output a single consolidated report:

```
## Chad Review — Report

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

### Verdict: [GO / NO-GO / CONDITIONAL]
[1-2 sentence summary of whether to commit as-is, fix something first, or stop and rethink]
```

## After the Report — Fix Prompt

If the verdict is NO-GO or CONDITIONAL, offer to generate a **fix prompt** the user can use to kick off a planning session. The fix prompt must:

1. **List every finding that needs action** — include the pass, severity, file path, and line numbers.
2. **Describe what each fix should accomplish** — not the implementation, but the outcome (e.g., "ghost.go should use Eastern time for the race date, matching how live races work").
3. **Reference existing patterns** — point to code that already does the right thing in the codebase.
4. **Separate required fixes from optional improvements** — CRITICAL and HIGH are required, MEDIUM and LOW are optional.
5. **End with a verification step** — "After fixing, run `/chad-review` again to confirm all issues are resolved."

Present the prompt in a copyable code block, then ask the user:

> "Want me to enter plan mode with this prompt, or do you want to edit it first?"

- If **enter plan mode**: enter plan mode using the generated fix prompt as the task.
- If **edit first**: show the prompt and wait for the user to modify it, then enter plan mode with the edited version.

## Execution Strategy

**Delegate passes to sub-agents in parallel.** Passes that only read the diff are self-contained and can run concurrently via the Agent tool. Single-message multi-tool-use batches the launches in parallel.

**Model requirement: every sub-agent launched by this skill MUST pass `model: "opus"`.** Code review is high-judgment work where reasoning quality matters more than speed, so Opus is the default. Never launch a chad-review sub-agent on haiku or sonnet.

### Phase A — Passes 1, 2, 3, 5, 6, 7 in parallel (single Agent call batch)

Launch all six as sub-agents in ONE message (six `Agent` tool uses in a single response). Each sub-agent gets:
- The full diff captured in pre-flight (inline, as part of the prompt).
- The changed files list.
- A clear, self-contained brief — the sub-agent cannot see the parent conversation, so repeat project context it needs (e.g. "this project uses an OpenAPI spec at `docs/openapi.yaml`, validated via `make validate-openapi`").
- Explicit output format (e.g. "Report under 300 words. Structure: findings list, each with severity, file:line, one-sentence explanation.").
- **`model: "opus"`** on every Agent call.

Suggested `subagent_type` per pass (all run on `model: "opus"`):
- **Pass 1 (STRUCTURAL)** → `Explore` with thoroughness `medium`. Fast grep-heavy work.
- **Pass 2 (BEHAVIORAL)** → `feature-dev:code-reviewer` or `general-purpose`. Needs judgment, not speed.
- **Pass 3 (SPEC DRIFT)** → `general-purpose`. Needs to both read files AND run project-specific commands like spec validators, regeneration scripts, route-parity tests. Include the project's specific commands and paths in the prompt — detect them from the project layout during pre-flight.
- **Pass 5 (TEST COVERAGE)** → `Explore` with thoroughness `medium`. Locates test files and greps for references to new symbols.
- **Pass 6 (OBSERVABILITY)** → `feature-dev:code-reviewer` or `general-purpose`. Judgment-heavy: what counts as sufficient logging varies by code path.
- **Pass 7 (DOCUMENTATION)** → `general-purpose`. Needs to read doc files and compare against the diff; may need to check for presence of godoc/jsdoc/docstrings on new symbols.

Wait for all six sub-agent results before proceeding.

### Phase B — Pass 4 (TEST) in the parent turn

Do not delegate tests. Run `go test` / `npx vitest` / `pytest` / etc. directly in the parent so test output streams to the user. Tests may reveal failures that need immediate follow-up, and the parent has the full context to propose fixes.

### Phase C — Pass 8 (ADVERSARIAL) in the parent turn

Do not delegate. Pass 8 is informed by *everything* the prior passes found — the parent has all that context already, and spinning up a sub-agent would either duplicate the diff read or lose the prior findings. Run adversarial probes inline, using any targeted tool calls (grep, file reads) needed to confirm edge cases.

### Writing sub-agent prompts

Each sub-agent prompt MUST be self-contained:
- State the goal in one sentence.
- Include the full diff or a specific file list (sub-agents cannot see your conversation).
- Name the project's specific spec files / validation commands / test harness / doc locations (detect these during pre-flight; if not found, tell the sub-agent the convention is absent and to mark sub-checks N/A).
- Specify the output format and word budget.
- Remind them: read-only, never edit or commit.

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

Output: <format + word budget>. Read-only — do not edit files or run commits.
```

Example Agent tool call (model is REQUIRED):

```json
{
  "description": "Pass 1 STRUCTURAL review",
  "subagent_type": "Explore",
  "model": "opus",
  "prompt": "<self-contained prompt as above>"
}
```

## Rules

- NEVER edit any source file
- NEVER commit anything
- NEVER apply proposed fixes — only show them
- NEVER skip a pass — run all 8 even if early passes find nothing (mark "Clean" or "N/A" as appropriate)
- ALWAYS pass `model: "opus"` on every Agent sub-agent launch — code review is a judgment task
- Pass 3 may run type generators, spec validators, and route-parity tests — these are non-destructive
- If the diff is enormous (50+ files), ask the user if they want to scope the review to specific directories
- If the project's conventions don't match any of the sub-check patterns, mark "N/A" and continue — don't fail the pass
