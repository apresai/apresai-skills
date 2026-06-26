---
name: chad-review
description: 9-pass autonomous pre-commit code review. Use when the user wants to review their changes before committing, asks for a pre-commit review, says "review before I commit" or "review the last commit", or invokes /chad-review. Reviews uncommitted working-tree changes (staged, unstaged, and untracked) if any exist; otherwise falls back to the last commit. Runs structural, behavioral, spec-drift, test, test-coverage, observability, documentation, adversarial, and dependency-freshness analysis.
---

# Chad Review — 9-Pass Code Review

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
4. The captured diff is the input for Passes 1 through 8. The changed files list drives Pass 4 test selection and Pass 5 coverage selection. Pass 9 (FRESHNESS) is whole-project: it audits the project's dependencies regardless of the diff, and reads the changed files list only to prioritize and tag deps the change touched.
5. **Route per-pass agents by language family.** Run the bundled
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
   language and you spawn one set of Phase A sub-agents PER block, plus
   ONE whole-project FRESHNESS agent for the review overall (a CDK + Go
   diff = 12 per-language sub-agents + 1 FRESHNESS agent = 13 launched in
   a single Agent batch). Each language's findings flow into one shared
   Final Report.

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

### Language-specific grep patterns

Use the patterns below to construct the grep command for each removed symbol. Restrict file extensions with `--include` to reduce noise and false positives.

**Go** — different symbol kinds warrant different patterns:
- Function or method removed: `grep -rn "SymbolName" . --include="*.go"` — matches calls, type assertions, and func values
- Type or struct removed: `grep -rn "\bSymbolName\b" . --include="*.go"` — word-boundary match avoids partial hits on `SymbolNameExtended`
- Interface removed: also check for `var _ SymbolName =` compile-time interface guards
- Constant or variable removed: `grep -rn "SymbolName" . --include="*.go"` — also check `iota` blocks for enum holes
- Unexported symbol (lowercase): scope the search to the same package directory only; no need to scan the whole repo

**TypeScript / JavaScript** — export style determines where references live:
- Named export removed (`export function Foo`, `export const Foo`, `export type Foo`): `grep -rn "Foo" . --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx"`; also check barrel files (`index.ts`) that re-export it
- Default export removed: search for `import Foo from`, `import { default as Foo }`, and the file path in dynamic `import()` expressions
- Type-only import removed (`import type { Foo }`): grep in `.ts` and `.tsx` only; these can't appear in `.js` at runtime but can still break build

**Swift** — visibility level changes the search scope:
- `public` or `open` symbol removed: search the entire workspace including consuming targets: `grep -rn "SymbolName" . --include="*.swift"`
- `internal` symbol removed: search only files in the same module/target directory
- Protocol removed: also search for conformances (`extension X: RemovedProtocol`) and `any RemovedProtocol` / `some RemovedProtocol` usage

**Python**:
- Function or class removed: `grep -rn "SymbolName" . --include="*.py"` — also check `from module import SymbolName` forms
- `__all__` entries: if the file defines `__all__`, check it still exports the right names and downstream `from module import *` consumers aren't silently broken

### When to use a language server instead of grep

Grep produces false positives (string literals, comments, unrelated symbols that share a name). Escalate to a language server when:
- The symbol name is short or generic (e.g., `Get`, `Handler`, `Config`, `Error`) where grep returns too many hits to triage manually
- The change involves method renaming on an interface with multiple implementations — `gopls references` or `tsserver findAllReferences` gives precise call sites
- A TypeScript type is removed and you need to confirm no inferred usages remain (TypeScript's structural typing means grep misses widened uses)

Practical commands:
- Go: `gopls references -format=json <file>:<line>:<col>` (requires `gopls` in PATH)
- TypeScript: `npx tsgo --findAllReferences` or let `npx tsc --noEmit` surface the error (fastest for CI)
- Swift: `sourcekit-lsp` via `xcrun sourcekit-lsp` — prefer `xcodebuild build` to surface missing-symbol errors directly

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

1. Look for type-generation scripts in the project using the language-specific detection patterns below.
2. If found, run the relevant target/script.
3. Run `git diff` on the generated artifact paths (look for files matching `*.generated.{ts,go,swift,kt}`, `*_gen.*`, `generated/`, `**/types/api.*`).
4. If any generated file has uncommitted changes after regeneration → types are stale.
5. Report: `SPEC DRIFT [types]: <path>/api.generated.ts is stale — regeneration produced changes` or "Generated types are fresh."
6. If no codegen is detected by any pattern below, mark "3d: N/A — no codegen detected."

#### Codegen detection by language/tool

**Go — oapi-codegen:**
- Config file: look for `oapi-codegen.yaml`, `oapi-codegen.yml`, or any `.yaml` containing `package:` and `generate:` keys at top level (oapi-codegen v2 config format)
- Also check: `//go:generate oapi-codegen` directives in any `.go` file (`grep -rn "go:generate.*oapi-codegen" . --include="*.go"`)
- Makefile targets: `grep -n "oapi-codegen\|generate-types\|gen-types" Makefile`
- Output paths: typically `internal/api/*.gen.go`, `pkg/api/*.gen.go`, or wherever `output` is set in the config
- Run command: `go generate ./...` (respects `//go:generate` directives) or `make <target>`

**TypeScript — openapi-typescript / hey-api:**
- `package.json` scripts: look for keys matching `openapi-ts`, `openapi-typescript`, `generate`, `codegen`, `gen:types` — `grep -A1 '"scripts"' package.json | grep -E "openapi|codegen|gen"` or parse with `jq '.scripts | to_entries[] | select(.value | test("openapi|codegen|openapi-ts"))' package.json`
- Config file: `openapi-ts.config.ts`, `openapi-ts.config.js`, or `hey-api` config block in `package.json`
- Run command: `npm run generate` / `pnpm openapi-ts` / `npx openapi-typescript openapi.yaml -o src/types/api.d.ts`
- Output paths: typically `src/types/api.d.ts`, `src/lib/api.ts`, `generated/`

**Swift — swift-openapi-generator:**
- Plugin presence: check `Package.swift` for `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`
- Config file: `openapi-generator-config.yaml` in the target's source directory (required by the plugin — its absence means the plugin won't run)
- Input spec: `openapi.yaml` co-located with the config file in the same target directory
- Generated output: artifacts are produced at build time into `.build/` and are not committed — so "freshness" here means checking that `openapi.yaml` and `openapi-generator-config.yaml` are in sync with any handwritten types that duplicate generated ones
- Run command: `swift build` (plugin runs automatically); no separate generation step needed

**Python — Pydantic model/spec sync:**
- No standard auto-generation tooling comparable to oapi-codegen; Pydantic models are usually written by hand and must be kept in sync with the OpenAPI spec manually
- Detection: look for `generate_openapi_schema`, `app.openapi()`, or `schema_json()` calls that export the spec from models — if found, the spec is derived from models (models are the source of truth, not the other way around)
- For FastAPI projects: the generated spec at `/openapi.json` reflects live models; drift is detected by running `pytest` and checking the spec endpoint, not by a separate codegen step
- If a project uses `datamodel-code-generator` (generates Pydantic models from spec): `grep -rn "datamodel-codegen" Makefile package.json scripts/ 2>/dev/null`

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
2. Run only those tests using the project's test runner. Use the scoping commands below to avoid running the entire suite:

**Go — package-level scoping:**
- Run the package(s) that contain modified files: `go test ./internal/mypackage/... -count=1`
- To scope further to specific tests by name: `go test ./internal/mypackage/... -run TestFunctionName -count=1`
- `go list ./...` lists all packages; cross-reference against the changed file paths to identify affected packages
- The `-count=1` flag disables the test cache, ensuring you get a fresh run even if inputs haven't changed on disk
- For table-driven tests, `-run TestName/SubtestName` targets a specific `t.Run` case (slashes separate parent and sub-test names)

**TypeScript — related-file targeting:**
- Vitest (preferred): `npx vitest related --run <changed-source-file1> <changed-source-file2>` — Vitest traces the import graph and runs only tests that transitively import the changed files
- Vitest with staged changes: `npx vitest --changed --run` (defaults to uncommitted changes) or `npx vitest --changed HEAD~1 --run` for the last commit
- lint-staged integration pattern: `vitest related --run` in `lint-staged` config covers staged files automatically
- Jest fallback: `npx jest --findRelatedTests <file1> <file2> --passWithNoTests`
- Single test file: `npx vitest run path/to/component.test.ts`

**Swift — target and class scoping:**
- Run a specific test class: `xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:<TestTarget>/<TestClass>`
- Run a specific test method: `xcodebuild test -scheme <Scheme> -destination '...' -only-testing:<TestTarget>/<TestClass>/<testMethodName>`
- For Swift Package Manager projects (no Xcode scheme): `swift test --filter <TestClassName>` or `swift test --filter <TestClassName>/<methodName>`
- Note: `-only-testing:` accepts a slash-separated path; the test target name comes from the scheme's test action, not the module name

**Python — file and mark-based scoping:**
- Single file: `pytest path/to/test_file.py -v`
- Single test function: `pytest path/to/test_file.py::test_function_name -v`
- Single test class method: `pytest path/to/test_file.py::TestClass::test_method -v`
- By mark: `pytest -m "unit" -v` (requires marks defined in `pytest.ini` or `pyproject.toml`)
- Related imports (approximate): `pytest --co -q` to collect without running, then inspect

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
3. For each new code branch, error case, feature flag, or conditional path, check whether a test exercises it — see the language-specific patterns below for what "covered" looks like in each language.
4. For bug fixes: verify a **regression test** exists — a test that would have failed before the fix and passes after.
5. Flag missing coverage:
   - **CRITICAL**: New public API endpoint, HTTP handler, Lambda entry point, or cron entry point with zero tests
   - **HIGH**: New business-logic branch (new error case, new conditional, new feature flag) with no test
   - **HIGH**: Bug fix with no regression test
   - **MEDIUM**: Modified function where existing tests don't cover the new behavior
   - **LOW**: Internal helper with no direct test but covered transitively by caller tests
6. Report: `TEST COVERAGE: handler HandleCreateAutoTaunt has no test in <path>/autotaunt_test.go`

If zero issues, report "TEST COVERAGE: Clean — all changes have corresponding tests."

### What counts as "covered" per language

**Go:**
- The idiomatic standard is **table-driven tests**: a slice of structs (usually named `tests` or `cases`) iterated with `for _, tc := range tests { t.Run(tc.name, func(t *testing.T) { ... }) }`. A new code branch is covered if it has at least one row in the table that exercises it.
- `t.Run` subtests are the primary mechanism — check that subtests are named descriptively enough to identify which branch they cover (e.g., `"error: missing field"`, `"success: cache hit"`)
- A function with no `t.Run` subtests and a single code path is acceptable only if the behavior is truly trivial; anything with an `if`/`switch`/error return needs at least two cases
- Check `t.Helper()` usage — helper functions should call `t.Helper()` so failures point to the calling test, not the helper

**TypeScript (Vitest / Jest):**
- Coverage is `describe` / `it` (or `test`) blocks that call the modified function or render the modified component
- Parameterized coverage uses `it.each` (Vitest/Jest): `it.each([[input1, expected1], [input2, expected2]])('description %s', (input, expected) => { ... })` — look for `it.each` or `test.each` tables when multiple branches exist
- For React components: `@testing-library/react` render + assertion is the minimum; check that user-visible branches (loading state, error state, empty state) each have a `render` + assertion pair
- Type-level coverage: if a type was changed, check for `expectTypeOf` or `assertType` calls (Vitest supports these natively)

**Swift:**
- XCTest parameterization: `XCTestCase.invokeTest` can be overridden to run the same test with multiple parameters, but this is uncommon. More commonly, multiple `func test<CaseName>()` methods cover individual branches.
- swift-testing (available iOS 17+ / Swift 5.9+): `@Test(arguments: [value1, value2])` parameterizes a test function — each argument becomes a separate test run. Look for `@Test` attribute and `#expect` / `#require` macros instead of `XCTAssert*`.
- A new `public` function with no corresponding `func test*` method in any test target is an automatic HIGH gap.
- Check `@Suite` groupings in swift-testing — suites should map to the module under test, making coverage gaps visible by structure.

**Python:**
- `pytest.mark.parametrize` is the standard parameterization decorator: `@pytest.mark.parametrize("input,expected", [(val1, exp1), (val2, exp2)])`. A new branch without a corresponding parametrize case is a gap.
- Check for fixture reuse — fixtures in `conftest.py` that set up the system under test should be updated when new initialization parameters are added
- `unittest`-style: `subTest` context manager (`with self.subTest(case=name):`) serves the same role as table-driven tests; check that new branches have a `subTest` block

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

### Language-specific observability patterns

**Go:**
- Preferred logger is `log/slog` (standard library since Go 1.21). Check that handlers use `slog.With(ctx, ...)` to attach context-derived fields rather than constructing ad-hoc string messages
- For Lambda: the `lambda.NewLogHandler()` function (from `github.com/aws/aws-lambda-go/lambda`) returns a `slog.Handler` that injects `requestId` from the Lambda context automatically and respects `AWS_LAMBDA_LOG_FORMAT` / `AWS_LAMBDA_LOG_LEVEL`. A new Lambda handler that uses `slog.Default()` without setting this handler will produce unstructured logs in CloudWatch.
- Error wrapping: `fmt.Errorf("operation failed: %w", err)` is the correct idiom. Flag any use of `errors.Wrap` from `github.com/pkg/errors` — that package is deprecated; the stdlib `%w` verb replaces it. Also flag bare `return err` without context in functions that could fail for multiple reasons.
- Goroutine-spawning code: confirm the spawned goroutine logs its own errors — errors returned to a closed channel or silently dropped goroutine panics are invisible without explicit logging inside the goroutine body.

**TypeScript / Node.js:**
- Preferred structured loggers: `pino` (lowest overhead, JSON by default, ideal for Lambda and container workloads) or `winston` with JSON transport. Flag `console.log` / `console.error` in production code paths — these produce unstructured output that CloudWatch Logs Insights cannot query by field.
- For Node.js Lambda: ensure the logger writes to stdout/stderr (pino's default); AWS collects stdout. Confirm `requestId` from the Lambda context is bound to the logger instance at handler entry: `const log = logger.child({ requestId: context.awsRequestId })`.
- Promise rejection: check every `async` function for unhandled rejection paths. A `.catch()` that only logs without re-throwing is often acceptable; a `.catch(() => {})` or a missing `.catch()` on a fire-and-forget chain that could fail is a CRITICAL gap.
- Next.js Server Components / Route Handlers: `console.error` is acceptable for server-side logging in Next.js but loses structure; prefer a pino instance imported from a shared logger module.

**Swift (iOS / macOS):**
- Preferred API: `Logger` from the `OSLog` framework (available iOS 14+, macOS 11+). Flag `print()` statements in production code — they write to stdout but are not captured by the unified logging system and are stripped in release builds.
- Logger instances should declare a subsystem (reverse-DNS, e.g., `com.myapp.networking`) and category (e.g., `"API"`, `"Auth"`). This enables filtering in Console.app and `log stream` during debugging.
- Privacy: `Logger` automatically redacts interpolated values in release builds unless marked `.public`. Logging a value that must be visible in production (e.g., a request ID, an error code) must use `\(value, privacy: .public)`. Check that PII (names, emails, tokens) is NOT marked `.public`.
- `os_signpost` for performance: new code paths involving animation, image decode, or network round-trips benefit from signpost intervals (`OSSignposter`) for Instruments profiling — flag absence as LOW in performance-sensitive paths.

**Python:**
- Preferred structured logger: `structlog` (produces JSON or key-value output, integrates with stdlib `logging`). Flag bare `logging.info("message %s" % val)` — use `log.info("message", key=val)` with structlog's bound logger for queryable fields.
- Error chaining: `raise ValueError("context") from original_exc` is the correct idiom. Flag bare `raise ValueError("context")` inside an `except` block — it loses the original traceback.
- FastAPI / Lambda: confirm the request ID or correlation ID is extracted from the event/request and bound to the logger at handler entry.

## Pass 7 — DOCUMENTATION

Goal: Every user-visible, operator-visible, or API-visible change is documented. Stale docs are worse than missing docs.

1. For each change in the diff, determine which docs should reflect it:
   - **README.md** — setup steps, env vars, build/deploy commands, prerequisites
   - **API specs** — `api.yaml` / `openapi.yaml` endpoint, schema, and example updates
   - **Architecture / design docs** — files under `docs/`, ADRs, runbooks
   - **Data model docs** — `docs/data-model.md`, `docs/dynamodb-data-model.md`, or equivalent
   - **Inline doc comments** — godoc on exported Go symbols, TSDoc/JSDoc on exported TS symbols, Swift doc comments on public APIs, Python docstrings — see language conventions below
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

### Language-specific doc comment conventions

**Go — godoc:**
- Every exported identifier (function, type, method, constant, variable, package) must have a doc comment that begins with the identifier's name: `// FetchUser retrieves a user by ID from DynamoDB.`
- Package-level comments go in a file named `doc.go` or at the top of the main file in the package: `// Package billing handles subscription lifecycle and Stripe webhooks.`
- Multi-paragraph comments are fine; use blank `//` lines to separate paragraphs. Avoid markdown inside godoc — it renders as plain text on pkg.go.dev.
- Flag: exported symbol added or modified without a preceding `// SymbolName ...` comment.

**TypeScript — TSDoc:**
- Use `/** ... */` block comments (not `//`) directly above the exported symbol. TSDoc tags: `@param name - description`, `@returns description`, `@throws ErrorType - when X`, `@example` with a fenced code block.
- `@example` blocks are especially valuable for utility functions and hooks — check that non-trivial new exports include at least one.
- For React components: document props via the interface/type's JSDoc block, not on the component function itself.
- Flag: exported function, class, or type added without a `/** ... */` block.

**Swift — documentation comments:**
- Use `///` (triple-slash) for inline doc comments on each line, or `/** ... */` for block comments. `///` is the Apple-idiomatic style.
- Standard tags (rendered by Xcode Quick Help): `- Parameter name: description`, `- Returns: description`, `- Throws: ErrorType — when X`, `- Note: additional context`, `- Warning: important caveat`.
- Example:
  ```swift
  /// Fetches the leaderboard for a given group.
  ///
  /// - Parameter groupID: The ULID of the group to query.
  /// - Returns: An array of `LeaderboardEntry` sorted by score descending.
  /// - Throws: `APIError.notFound` if the group does not exist.
  func fetchLeaderboard(groupID: String) async throws -> [LeaderboardEntry]
  ```
- Flag: new `public` or `open` function, type, or property without `///` doc comments.

**Python — docstrings:**
- Use triple-quoted strings (`"""..."""`) immediately after the `def` or `class` statement.
- Preferred styles (pick one per project, be consistent): **Google style** (`Args:`, `Returns:`, `Raises:` sections), **NumPy style** (underlined section headers), or **Sphinx style** (`:param name:`, `:type name:`, `:returns:`, `:rtype:`).
- Minimum for a public function: one-line summary + `Args` + `Returns` + `Raises` (if it raises).
- Flag: new public function or class without a docstring, or existing docstring that no longer matches the updated signature (wrong param name, missing new param).

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

Also probe these **language-specific gotchas** that the generic checklist above misses:

**Go:**
- **Nil map write**: assigning to a nil map (`var m map[string]int; m["key"] = 1`) panics. Check any new map variable that is declared but not initialized with `make`. Reading from a nil map is safe (returns zero value) — writing is not.
- **Nil slice vs empty slice**: a nil slice marshals to JSON `null`; a non-nil zero-length slice marshals to `[]`. If the API contract requires `[]` on empty results (common for REST list endpoints), check that handlers return `make([]T, 0)` not `var result []T` when the query produces no rows.
- **Goroutine leak**: any new `go func()` call must have a clear exit path. The goroutine must either read from a done channel, respect a `context.Context` cancellation, or be bounded by a `sync.WaitGroup`. A goroutine that blocks on a channel send with no receiver, or on a network call with no timeout, leaks. Flag: new goroutine without context cancellation or explicit termination condition.
- **Context cancellation not checked**: new code that calls `ctx.Done()` or passes `ctx` to a library but then ignores the returned error (`_ = db.QueryContext(ctx, ...)`) defeats the purpose. Check that context errors are propagated.
- **`errors.Wrap` from `pkg/errors`**: deprecated. Should be `fmt.Errorf("context: %w", err)`.

**TypeScript / Next.js:**
- **`undefined` vs `null` conflation**: TypeScript distinguishes `undefined` (variable not set) from `null` (explicitly empty), but JSON serialization and optional chaining can blur this. A field typed `string | undefined` that becomes `null` at runtime (from a DB or API) will pass the type check but break `=== undefined` guards. Flag new optional fields that lack `?? null` normalization.
- **Next.js hydration mismatch**: any value computed differently on server vs client (current date/time, `Math.random()`, `window` access, user-agent detection, cookies/localStorage) will cause a hydration error if used during render. Flag new code in Server Components or page render that touches non-deterministic browser-only values without `useEffect` or `dynamic(() => ..., { ssr: false })`.
- **Unhandled promise rejection**: a `Promise` returned from an async function that is not `await`ed and has no `.catch()` silently swallows errors. In Node.js Lambda, unhandled rejections terminate the process. Flag: `someAsyncFn()` called without `await` in a non-void fire-and-forget context where failures should be observable.
- **`as` type assertion without validation**: `const data = response as MyType` bypasses runtime checking. If the data comes from an external source (API response, JSON.parse, URL params), flag the missing runtime validation (Zod, type guard, etc.).

**Swift:**
- **Implicitly-unwrapped optionals (`!`)**: new `var foo: SomeType!` declarations are a smell — they crash at runtime if accessed before initialization. Flag any new IUO outside of `@IBOutlet` patterns (where they're forced by the storyboard lifecycle). Prefer `guard let` or `if let` unwrapping.
- **`Sendable` conformance for concurrency**: any type passed across actor boundaries (`async`/`await`, `Task`, `actor`) must be `Sendable`. New types that hold reference-type properties and are passed to `Task { }` or sent to an actor without `@unchecked Sendable` will produce a compiler warning in Swift 5.9+ strict concurrency mode and an error in Swift 6. Flag new types used in concurrency contexts that lack explicit `Sendable` or `@unchecked Sendable` with an explanation.
- **Actor reentrancy**: code that reads state, `await`s, then acts on the stale state is a reentrancy bug. After any `await` inside an actor method, other tasks may have mutated the actor's state. Flag new actor methods with logic of the form "read state → await → act on state" without re-checking the state post-await.

**Python:**
- **Mutable default arguments**: `def fn(items=[])` shares the same list across all calls. Any new function with a mutable default (list, dict, set) is a HIGH bug. The fix is `def fn(items=None): if items is None: items = []`.
- **Async exception propagation**: `asyncio.create_task()` schedules a coroutine but exceptions in the task are silently discarded unless the task is awaited or the exception handler is attached via `task.add_done_callback`. Flag new `create_task()` calls without an exception handler or subsequent `await`.
- **`except Exception` too broad**: catching `Exception` (or bare `except`) and only logging swallows unexpected errors. If a new `except` block logs and continues, verify it's intentional and the logged error is actionable.

Rate each finding:
- **CRITICAL**: Will cause data loss, security bypass, or crash in production
- **HIGH**: Likely to cause user-visible bugs under realistic conditions
- **MEDIUM**: Edge case that could bite someone eventually
- **LOW**: Theoretical concern, unlikely but worth noting

## Pass 9 — FRESHNESS

Goal: Every direct dependency, framework, and language runtime is current enough to be safe, carries no known CVE and no end-of-life runtime, and each staleness call separates an overdue or security-driven upgrade from one that is still too early to take.

Unlike the other passes, Pass 9 is a WHOLE-PROJECT audit. It runs on every chad-review regardless of what the diff touches. It reads the changed-files list only to prioritize and to tag dependencies the current change touched, never to gate whether the pass runs.

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

### Ecosystem-specific manifest, version, and security sources

`osv-scanner -r .` is a language-agnostic CVE fallback that reads most lockfiles at once and is the cheapest single scan.

**Go (go.mod):** find `go.mod` (skip `vendor/`); direct deps are `require` entries NOT marked `// indirect`; runtime is the `go 1.xx` directive (Go supports the two latest majors). Security: `govulncheck ./...` or `osv-scanner --lockfile=go.mod`. Runtime EOL: endoflife.date/go.

**Node / TypeScript (package.json):** find `package.json` (skip `node_modules/`, `.next/`); current from `dependencies` / `devDependencies` plus the lockfile; runtime from `engines.node` or `.nvmrc`. Resolve `next`, `react`, and the framework deps the route script already surfaces. Security: `npm audit` / `pnpm audit` or `osv-scanner -r .`. Node EOL: endoflife.date/nodejs. Next.js patches the current and previous major.

**Flutter / Dart (pubspec.yaml):** find `pubspec.yaml` (skip `.dart_tool/`, `build/`); current from `dependencies` plus `pubspec.lock`; SDK from `environment:`. Security: `dart pub outdated --mode=security` or `osv-scanner --lockfile=pubspec.lock`.

**Swift / SPM (Package.swift, Package.resolved):** find `Package.swift` (skip `.build/`) plus the sibling `Package.resolved` (exact pinned versions, git-tag based); toolchain from `swift-tools-version`. Security: no first-party scanner; use `osv-scanner --lockfile=Package.resolved` plus Dependabot advisories.

**Python (pyproject.toml, requirements.txt):** find them (skip `.venv/`); current from `[project.dependencies]` / `[tool.poetry.dependencies]` plus `poetry.lock` / `uv.lock`; runtime from `requires-python`. Security: `pip-audit` or `osv-scanner -r .`. Python EOL: endoflife.date/python.

**Rust (Cargo.toml):** find `Cargo.toml` (skip `target/`); current from `[dependencies]` plus `Cargo.lock`; MSRV from `rust-version`. Security: `cargo audit` or `osv-scanner --lockfile=Cargo.lock`.

## Performance Budget

The review should complete in under 60 seconds for a typical PR (5-10 file changes). The parallel Phase A fan-out is the primary lever — seven sub-agents running concurrently means the wall-clock time is dominated by the slowest single pass, not the sum.

If the review is running long, cut in this order:

1. **Pass 9 (FRESHNESS)**: the context7 version-resolution loop is network-bound and is the first thing to cap when the review runs long. Reduce the soft-cap, or resolve versions only for runtimes and core frameworks. NEVER skip the local security and EOL scan (`osv-scanner` / `govulncheck` / `pip-audit`): a CVE or EOL runtime is CRITICAL and the scan is cheap.
2. **Pass 3 (SPEC DRIFT)**: sub-checks 3d and 3g (type regeneration and spec lint) are the most expensive because they compile or invoke external tools. If the diff has no handler changes, mark 3a–3c N/A immediately without running the generators.
3. **Pass 4 (TEST)**: if the project's test suite is slow (full compile + integration tests), scope to `-run TestFunctionName` rather than `./...`. Only run the packages that contain changed files.
4. **Pass 1 (STRUCTURAL)**: on diffs with many removed symbols, grep can be slow on large codebases. Scope grep to `--include="*.go"` / `--include="*.ts"` rather than all file types; skip `vendor/` and `node_modules/` aggressively.
5. **Phase B / Phase C (TEST + ADVERSARIAL)**: these run in the parent turn. If the sub-agents in Phase A are still running, proceed to Phase C adversarial reasoning (no tool calls needed) so it's ready to report when Phase A completes.

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
4. **Separate required fixes from optional improvements** — CRITICAL and HIGH are required, MEDIUM and LOW are optional. One exception: a Pass 9 FRESHNESS CRITICAL that the diff did not touch (a pre-existing CVE or end-of-life runtime) is a required follow-up to schedule now, not a blocker for this specific commit. List it under required fixes but label it "schedule now, does not block this commit", consistent with the CONDITIONAL verdict rule.
5. **Add a "Recommended — safe to do now" section for Pass 9 UPGRADE NOW (safe) findings** — every mature, non-breaking framework/dependency upgrade gets a line with its concrete bump (`current → target`) and a verify step (the build plus the test/integration suite that exercises it). These are not commit blockers, but they are the headline value of the freshness pass, so they get their own heading — never folded into "optional polish" and never dropped to the backlog. Explicitly **offer to perform them now** (in this change or an immediate fast-follow) rather than just listing them. Keep HOLD items out of this section (they carry a revisit signal instead).
6. **End with a verification step** — "After fixing, run `/chad-review` again to confirm all issues are resolved."

Present the prompt in a copyable code block, then ask the user:

> "Want me to enter plan mode with this prompt, or do you want to edit it first?"

- If **enter plan mode**: enter plan mode using the generated fix prompt as the task.
- If **edit first**: show the prompt and wait for the user to modify it, then enter plan mode with the edited version.

## Execution Strategy

**Delegate passes to sub-agents in parallel.** Passes that only read the diff are self-contained and can run concurrently via the Agent tool. Single-message multi-tool-use batches the launches in parallel.

**Model requirement: every sub-agent launched by this skill MUST pass `model: "opus"`.** Code review is high-judgment work where reasoning quality matters more than speed, so Opus is the default. Never launch a chad-review sub-agent on haiku or sonnet.

### Phase A — Passes 1, 2, 3, 5, 6, 7 (per language) plus Pass 9 FRESHNESS (whole-project) in parallel (single Agent call batch)

Launch all seven as sub-agents in ONE message (seven `Agent` tool uses in a single response for a single-language diff). Each sub-agent gets:
- The full diff captured in pre-flight (inline, as part of the prompt).
- The changed files list.
- A clear, self-contained brief — the sub-agent cannot see the parent conversation, so repeat project context it needs (e.g. "this project uses an OpenAPI spec at `docs/openapi.yaml`, validated via `make validate-openapi`").
- Explicit output format (e.g. "Report under 300 words. Structure: findings list, each with severity, file:line, one-sentence explanation.").
- **`model: "opus"`** on every Agent call.

**Pass 9 (FRESHNESS) is whole-project: launch it once per review, not once per language block.** Passes 1, 2, 3, 5, 6, 7 fan out per language block from the routing script; FRESHNESS is added once to the same batch no matter how many language blocks the script emits. Its brief:
- The dependency manifests discovered project-wide (or instruct it to discover them with the prune list in Pass 9).
- The changed files list, used ONLY to prioritize and tag `(diff-touched)` deps. State explicitly that the audit is whole-project and does not depend on the diff.
- context7 as the primary source for latest version and migration intelligence; a lightweight WebSearch only as a release-recency probe.
- Output: the recommendation table plus CRITICAL/HIGH severity lines, under about 350 words.
- **`model: "opus"`**, read-only, never edit or commit.

**Preferred path: use `chad-review-route.sh` output** (see Pre-flight step 5) — it picks the right specialist per language family in the diff.

**Fallback defaults** when the routing script is unavailable. These are Go-shaped: adequate for Go cmd Lambdas + shared packages, only OK for other languages. All run on `model: "opus"`:
- **Pass 1 (STRUCTURAL)** → `Explore` with thoroughness `medium`. Fast grep-heavy work.
- **Pass 2 (BEHAVIORAL)** → `feature-dev:code-reviewer` or `general-purpose`. Needs judgment, not speed.
- **Pass 3 (SPEC DRIFT)** → `general-purpose`. Needs to both read files AND run project-specific commands like spec validators, regeneration scripts, route-parity tests. Include the project's specific commands and paths in the prompt — detect them from the project layout during pre-flight.
- **Pass 5 (TEST COVERAGE)** → `Explore` with thoroughness `medium`. Locates test files and greps for references to new symbols.
- **Pass 6 (OBSERVABILITY)** → `feature-dev:code-reviewer` or `general-purpose`. Judgment-heavy: what counts as sufficient logging varies by code path.
- **Pass 7 (DOCUMENTATION)** → `general-purpose`. Needs to read doc files and compare against the diff; may need to check for presence of godoc/jsdoc/docstrings on new symbols.

For non-Go diffs, the routing script's specialist picks generally produce more accurate findings. The Context7 hints below are *examples* — the script emits the actual frameworks/deps the changed files import, so use whatever it prints:
- **CDK TypeScript** → `cloud-architect` for behavioral / observability passes (knows IAM idioms, drift sources, asset-path conventions); `typescript-pro` for test coverage. Context7: `aws-cdk-lib`.
- **Next.js / React** → `frontend-developer` for behavioral / test-coverage / observability (knows React rules-of-hooks, Server-vs-Client components, accessibility). Context7: derived from the project's `package.json` (e.g. `next`, `react`, `@tanstack/react-query`, `next-auth`).
- **Generic TypeScript / JS** (a Node Lambda, CLI, or library — neither CDK nor Next.js) → `typescript-pro`. Context7: resolved from the deps the changed files import.
- **iOS Swift** → `code-reviewer` is the best generic match (no native Swift specialist agent exists). Context7: `swift`, plus the Apple frameworks the diff actually imports — the script derives these per-diff (e.g. `StoreKit`, `Vision`, `AuthenticationServices`, `FoundationModels`), so they reflect the project under review rather than any fixed list.

Wait for all Phase A sub-agent results (the per-language passes plus the single FRESHNESS agent) before proceeding.

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
- NEVER skip a pass — run all 9 even if early passes find nothing (mark "Clean" or "N/A" as appropriate)
- ALWAYS pass `model: "opus"` on every Agent sub-agent launch — code review is a judgment task
- Pass 3 may run type generators, spec validators, and route-parity tests — these are non-destructive
- If the diff is enormous (50+ files), ask the user if they want to scope the review to specific directories
- If the project's conventions don't match any of the sub-check patterns, mark "N/A" and continue — don't fail the pass
