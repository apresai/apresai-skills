# chad-review pass reference (per-language / per-ecosystem detail)

Companion to `SKILL.md`, loaded on demand so the parent conversation never pays for languages the diff does not touch. When building a Phase A sub-agent prompt, paste ONLY the section(s) matching the pass and the language families the routing script detected. Passes 4 and 8 run in the parent: Read the relevant section at execution time.

Full path when installed: `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pass-reference.md`

---

## § Pass 1 — STRUCTURAL: language-specific grep patterns + language-server escalation

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


---

## § Pass 3 — SPEC DRIFT: codegen detection by language/tool

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


---

## § Pass 4 — TEST: test-scoping commands per language

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


---

## § Pass 5 — TEST COVERAGE: what counts as covered per language

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


---

## § Pass 6 — OBSERVABILITY: language-specific observability patterns

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


---

## § Pass 7 — DOCUMENTATION: language-specific doc comment conventions

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


---

## § Pass 8 — ADVERSARIAL: language-specific gotchas

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


---

## § Pass 9 — FRESHNESS: ecosystem-specific manifest, version, and security sources

### Ecosystem-specific manifest, version, and security sources

`osv-scanner -r .` is a language-agnostic CVE fallback that reads most lockfiles at once and is the cheapest single scan.

**Go (go.mod):** find `go.mod` (skip `vendor/`); direct deps are `require` entries NOT marked `// indirect`; runtime is the `go 1.xx` directive (Go supports the two latest majors). Security: `govulncheck ./...` or `osv-scanner --lockfile=go.mod`. Runtime EOL: endoflife.date/go.

**Node / TypeScript (package.json):** find `package.json` (skip `node_modules/`, `.next/`); current from `dependencies` / `devDependencies` plus the lockfile; runtime from `engines.node` or `.nvmrc`. Resolve `next`, `react`, and the framework deps the route script already surfaces. Security: `npm audit` / `pnpm audit` or `osv-scanner -r .`. Node EOL: endoflife.date/nodejs. Next.js patches the current and previous major.

**Flutter / Dart (pubspec.yaml):** find `pubspec.yaml` (skip `.dart_tool/`, `build/`); current from `dependencies` plus `pubspec.lock`; SDK from `environment:`. Security: `dart pub outdated --mode=security` or `osv-scanner --lockfile=pubspec.lock`.

**Swift / SPM (Package.swift, Package.resolved):** find `Package.swift` (skip `.build/`) plus the sibling `Package.resolved` (exact pinned versions, git-tag based); toolchain from `swift-tools-version`. Security: no first-party scanner; use `osv-scanner --lockfile=Package.resolved` plus Dependabot advisories.

**Python (pyproject.toml, requirements.txt):** find them (skip `.venv/`); current from `[project.dependencies]` / `[tool.poetry.dependencies]` plus `poetry.lock` / `uv.lock`; runtime from `requires-python`. Security: `pip-audit` or `osv-scanner -r .`. Python EOL: endoflife.date/python.

**Rust (Cargo.toml):** find `Cargo.toml` (skip `target/`); current from `[dependencies]` plus `Cargo.lock`; MSRV from `rust-version`. Security: `cargo audit` or `osv-scanner --lockfile=Cargo.lock`.

