# chad-review pass reference (per-language / per-ecosystem detail)

Companion to `commands/chad-review.md`, loaded on demand so nobody pays for
languages the diff does not touch. A Phase 1 sub-agent is given this file's PATH
and the section names it owns, and reads them itself; the parent does not paste
them. The TESTS run half and the BEHAVIOR AND RISK attack half execute in the
parent, which reads those sections at execution time.

| Section | Covers |
|---|---|
| § DRIFT | Symbol grep patterns, API-surface patterns, codegen detection, doc-comment conventions |
| § BEHAVIOR AND RISK | Language-specific gotchas for the attack probes |
| § TESTS | Per-language test scoping, and what "covered" looks like |
| § OBSERVABILITY | Logging, error-wrapping, and metric idioms |
| § FRESHNESS | Which oracle answers which evidence, and polarity judgment |
| § SIMPLIFY | Per-language simplification signals |
| § GATE | What a project's validation entrypoint should contain |

Full path when installed:
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pass-reference.md`

---

## § DRIFT

### `[symbol]` Grep patterns per language

Restrict extensions with `--include` to cut noise and false positives.

**Go**, by symbol kind:
- Function or method: `grep -rn "SymbolName" . --include="*.go"` matches calls,
  type assertions, and func values
- Type or struct: `grep -rn "\bSymbolName\b" . --include="*.go"`, word-boundary
  so `SymbolNameExtended` doesn't hit
- Interface: also check `var _ SymbolName =` compile-time guards
- Constant or variable: also check `iota` blocks for enum holes
- Unexported (lowercase): scope to the same package directory only

**TypeScript / JavaScript**, by export style:
- Named export removed (`export function Foo`, `export const Foo`,
  `export type Foo`): grep `.ts`, `.tsx`, `.js`, `.jsx`; also check barrel files
  (`index.ts`) that re-export it
- Default export removed: search `import Foo from`,
  `import { default as Foo }`, and the file path in dynamic `import()`
- Type-only import removed (`import type { Foo }`): `.ts`/`.tsx` only. These
  can't appear in `.js` at runtime but still break the build

**Swift**, by visibility:
- `public` or `open`: search the whole workspace including consuming targets
- `internal`: search only the same module or target directory
- Protocol: also search conformances (`extension X: RemovedProtocol`) and
  `any RemovedProtocol` / `some RemovedProtocol`

**Python**:
- Function or class: also check `from module import SymbolName` forms
- `__all__`: if the file defines it, check it still exports the right names and
  that downstream `from module import *` consumers aren't silently broken

### When to use a language server instead of grep

Grep produces false positives (string literals, comments, unrelated same-named
symbols). Escalate when the symbol name is short or generic (`Get`, `Handler`,
`Config`, `Error`) and grep returns too many hits to triage; when renaming a
method on an interface with several implementations; or when a TypeScript type
is removed and structural typing means grep misses widened uses.

- Go: `gopls references -format=json <file>:<line>:<col>`
- TypeScript: `npx tsgo --findAllReferences`, or let `npx tsc --noEmit` surface
  the error (fastest for CI)
- Swift: `xcrun sourcekit-lsp`, or prefer `xcodebuild build` to surface
  missing-symbol errors directly

### `[spec/*]` API-surface patterns per language

**Query params**: Go `r.URL.Query().Get("...")`, `mux.Vars(r)["..."]`;
TypeScript `req.query.X`, `searchParams.get("...")`,
`nextUrl.searchParams.get("...")`; Python `request.args.get("...")`,
`request.query_params.get("...")`.

**Response writes**: Go `writeJSON(...)`, `json.NewEncoder(w).Encode(...)`,
`c.JSON(...)`, inline `map[string]any{...}`; TypeScript `res.json(...)`,
`NextResponse.json(...)`, `return Response.json(...)`; Python
`JsonResponse(...)`, `jsonify(...)`.

**Request-body decoding**: Go `decodeJSON(r, &...)`,
`json.NewDecoder(r.Body).Decode(&...)`; TypeScript `await req.json()`, Zod
schemas in route handlers; Python `request.json`, Pydantic models on FastAPI
routes.

Identify the top-level keys of each response and the target struct or type of
each decode, then compare against the spec's response schema and `requestBody`
schema, following `$ref` to resolve.

### `[types]` Codegen detection by language and tool

**Go, oapi-codegen:**
- Config: `oapi-codegen.yaml`/`.yml`, or any `.yaml` with top-level `package:`
  and `generate:` keys (v2 config format)
- Directives: `grep -rn "go:generate.*oapi-codegen" . --include="*.go"`
- Makefile: `grep -n "oapi-codegen\|generate-types\|gen-types" Makefile`
- Output: typically `internal/api/*.gen.go`, `pkg/api/*.gen.go`, or wherever
  `output` points
- Run: `go generate ./...` (respects `//go:generate`) or `make <target>`

**TypeScript, openapi-typescript / hey-api:**
- Scripts: keys matching `openapi-ts`, `openapi-typescript`, `generate`,
  `codegen`, `gen:types`. Parse with
  `jq '.scripts | to_entries[] | select(.value | test("openapi|codegen|openapi-ts"))' package.json`
- Config: `openapi-ts.config.ts`/`.js`, or a `hey-api` block in `package.json`
- Run: `npm run generate`, `pnpm openapi-ts`, or
  `npx openapi-typescript openapi.yaml -o src/types/api.d.ts`
- Output: typically `src/types/api.d.ts`, `src/lib/api.ts`, `generated/`

**Swift, swift-openapi-generator:**
- Plugin: check `Package.swift` for
  `.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")`
- Config: `openapi-generator-config.yaml` in the target's source directory. Its
  absence means the plugin won't run
- Input: `openapi.yaml` co-located with that config
- Output is produced at build time into `.build/` and is not committed, so
  "freshness" here means checking that `openapi.yaml` and the config stay in
  sync with any handwritten types duplicating generated ones
- Run: `swift build`; the plugin runs automatically

**Python, Pydantic:**
- No standard generator comparable to oapi-codegen. Models are usually
  handwritten and kept in sync manually
- If `generate_openapi_schema`, `app.openapi()`, or `schema_json()` appears, the
  spec is derived FROM models, so models are the source of truth, not the
  reverse
- FastAPI: the spec at `/openapi.json` reflects live models, so drift shows up
  by running `pytest` and checking the spec endpoint, not via a codegen step
- If the project uses `datamodel-code-generator`:
  `grep -rn "datamodel-codegen" Makefile package.json scripts/ 2>/dev/null`

### `[comments]` Doc-comment conventions

**Go (godoc):** every exported identifier needs a comment beginning with its own
name: `// FetchUser retrieves a user by ID from DynamoDB.` Package comments go in
`doc.go` or atop the main file. Separate paragraphs with blank `//` lines. Avoid
markdown; it renders as plain text on pkg.go.dev. Flag an exported symbol added
or modified without a preceding `// SymbolName ...` comment.

**TypeScript (TSDoc):** `/** ... */` blocks (not `//`) directly above the export.
Tags: `@param name - description`, `@returns`, `@throws ErrorType - when X`,
`@example` with a fenced block. `@example` is especially valuable on utility
functions and hooks. For React components, document props via the interface's
JSDoc, not the component function. Flag a new exported function, class, or type
with no `/** ... */`.

**Swift:** `///` per line (Apple-idiomatic) or `/** ... */`. Xcode Quick Help
tags: `- Parameter name:`, `- Returns:`, `- Throws:`, `- Note:`, `- Warning:`.

```swift
/// Fetches the leaderboard for a given group.
///
/// - Parameter groupID: The ULID of the group to query.
/// - Returns: An array of `LeaderboardEntry` sorted by score descending.
/// - Throws: `APIError.notFound` if the group does not exist.
func fetchLeaderboard(groupID: String) async throws -> [LeaderboardEntry]
```

Flag a new `public` or `open` function, type, or property with no `///`.

**Python (docstrings):** triple-quoted, immediately after `def` or `class`. Pick
one style per project and stay consistent: Google (`Args:`, `Returns:`,
`Raises:`), NumPy (underlined headers), or Sphinx (`:param name:`, `:returns:`).
Minimum for a public function: one-line summary plus `Args`, `Returns`, and
`Raises` if it raises. Flag a new public function or class with no docstring, or
an existing docstring that no longer matches the signature.

---

## § BEHAVIOR AND RISK

Language-specific gotchas the generic attack checklist misses.

**Go:**
- **Nil map write**: assigning to a nil map (`var m map[string]int; m["k"] = 1`)
  panics. Check any new map declared without `make`. Reading a nil map is safe;
  writing is not.
- **Nil slice versus empty slice**: a nil slice marshals to JSON `null`; a
  non-nil zero-length slice marshals to `[]`. If the API contract requires `[]`
  on empty results (common for REST list endpoints), handlers must return
  `make([]T, 0)`, not `var result []T`.
- **Goroutine leak**: every new `go func()` needs a clear exit path. It must read
  from a done channel, respect `context.Context` cancellation, or be bounded by
  a `sync.WaitGroup`. A goroutine blocked on a send with no receiver, or on a
  network call with no timeout, leaks.
- **Context cancellation ignored**: passing `ctx` then discarding the error
  (`_ = db.QueryContext(ctx, ...)`) defeats the purpose.
- **`errors.Wrap` from `pkg/errors`**: deprecated. Should be
  `fmt.Errorf("context: %w", err)`.

**TypeScript / Next.js:**
- **`undefined` versus `null` conflation**: a field typed `string | undefined`
  that arrives as `null` from a DB or API passes the type check but breaks
  `=== undefined` guards. Flag new optional fields lacking `?? null`
  normalization.
- **Hydration mismatch**: any value computed differently on server and client
  (current time, `Math.random()`, `window`, user-agent, cookies, localStorage)
  causes a hydration error if used during render. Flag new Server Component or
  page-render code touching non-deterministic browser-only values without
  `useEffect` or `dynamic(() => ..., { ssr: false })`.
- **Unhandled promise rejection**: a promise neither awaited nor `.catch()`ed
  swallows errors silently. In Node Lambda, unhandled rejections terminate the
  process.
- **`as` assertion without validation**: `const data = response as MyType`
  bypasses runtime checking. If the data comes from an API response,
  `JSON.parse`, or URL params, flag the missing runtime validation.

**Swift:**
- **Implicitly-unwrapped optionals**: new `var foo: SomeType!` crashes at runtime
  if accessed before initialization. Flag any new IUO outside `@IBOutlet`, where
  the storyboard lifecycle forces it. Prefer `guard let` / `if let`.
- **`Sendable` conformance**: any type crossing an actor boundary (`async`,
  `Task`, `actor`) must be `Sendable`. New types holding reference-type
  properties and passed to `Task { }` warn under Swift 5.9 strict concurrency and
  error in Swift 6.
- **Actor reentrancy**: reading state, `await`ing, then acting on the stale read
  is a bug. After any `await` inside an actor method, other tasks may have
  mutated state. Flag read-await-act sequences with no post-await re-check.

**Python:**
- **Mutable default arguments**: `def fn(items=[])` shares one list across all
  calls. Any new mutable default (list, dict, set) is a HIGH bug. Fix:
  `def fn(items=None): if items is None: items = []`.
- **Async exception propagation**: `asyncio.create_task()` discards exceptions
  unless the task is awaited or a handler is attached via
  `task.add_done_callback`.
- **`except Exception` too broad**: catching broadly (or bare `except`) and only
  logging swallows unexpected errors. Verify intent and that the logged error is
  actionable.

---

## § TESTS

### Scoping commands per language (parent, run half)

**Go, package-level:**
- Packages containing modified files:
  `go test ./internal/mypackage/... -count=1`
- Narrow to a test by name:
  `go test ./internal/mypackage/... -run TestFunctionName -count=1`
- `go list ./...` lists packages; cross-reference against changed paths
- `-count=1` disables the test cache, forcing a fresh run
- For table-driven tests, `-run TestName/SubtestName` targets one `t.Run` case
  (slashes separate parent and sub-test)

**TypeScript, related-file targeting:**
- Vitest (preferred): `npx vitest related --run <file1> <file2>` traces the
  import graph and runs only tests that transitively import the changed files
- Uncommitted changes: `npx vitest --changed --run`; last commit:
  `npx vitest --changed HEAD~1 --run`
- Jest fallback:
  `npx jest --findRelatedTests <file1> <file2> --passWithNoTests`
- Single file: `npx vitest run path/to/component.test.ts`

**Swift, target and class scoping:**
- Class: `xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:<TestTarget>/<TestClass>`
- Method: append `/<testMethodName>` to `-only-testing:`
- SwiftPM (no scheme): `swift test --filter <TestClassName>` or
  `--filter <TestClassName>/<methodName>`
- `-only-testing:` takes a slash-separated path; the target name comes from the
  scheme's test action, not the module name

**Python, file and mark scoping:**
- File: `pytest path/to/test_file.py -v`
- Function: `pytest path/to/test_file.py::test_function_name -v`
- Class method: `pytest path/to/test_file.py::TestClass::test_method -v`
- By mark: `pytest -m "unit" -v` (marks defined in `pytest.ini` or
  `pyproject.toml`)

### What counts as covered (reviewer agent, coverage half)

**Go:** the idiom is **table-driven tests**, a slice of structs (usually `tests`
or `cases`) iterated with
`for _, tc := range tests { t.Run(tc.name, func(t *testing.T) { ... }) }`. A new
branch is covered if at least one row exercises it. Check that subtest names
identify the branch (`"error: missing field"`, `"success: cache hit"`). A
function with no subtests and one code path is acceptable only if the behavior is
truly trivial; anything with an `if`, `switch`, or error return needs at least
two cases. Helpers should call `t.Helper()` so failures point at the caller.

**TypeScript (Vitest / Jest):** coverage is `describe`/`it` blocks calling the
modified function or rendering the modified component. Parameterized coverage
uses `it.each` / `test.each` tables when multiple branches exist. For React
components, `@testing-library/react` render plus assertion is the minimum, and
each user-visible branch (loading, error, empty) needs its own render-plus-assert
pair. For changed types, check for `expectTypeOf` or `assertType`.

**Swift:** XCTest usually covers branches with multiple `func test<CaseName>()`
methods. swift-testing (iOS 17+ / Swift 5.9+) parameterizes with
`@Test(arguments: [v1, v2])`; look for `@Test` plus `#expect` / `#require` rather
than `XCTAssert*`. A new `public` function with no corresponding `func test*` in
any test target is an automatic HIGH gap. `@Suite` groupings should map to the
module under test, which makes gaps visible structurally.

**Python:** `@pytest.mark.parametrize("input,expected", [...])` is the standard.
A new branch with no matching parametrize case is a gap. Check fixture reuse:
`conftest.py` fixtures that set up the subject should be updated when new
initialization parameters appear. For `unittest`, the `subTest` context manager
(`with self.subTest(case=name):`) plays the table-driven role.

---

## § OBSERVABILITY

**Go:**
- Preferred logger is `log/slog` (stdlib since Go 1.21). Handlers should use
  `slog.With(ctx, ...)` to attach context-derived fields rather than building
  ad-hoc strings.
- Lambda: `lambda.NewLogHandler()` (from `github.com/aws/aws-lambda-go/lambda`)
  returns a `slog.Handler` that injects `requestId` from the Lambda context and
  respects `AWS_LAMBDA_LOG_FORMAT` / `AWS_LAMBDA_LOG_LEVEL`. A new Lambda handler
  using bare `slog.Default()` produces unstructured CloudWatch logs.
- Error wrapping: `fmt.Errorf("operation failed: %w", err)`. Flag
  `errors.Wrap` from `github.com/pkg/errors` (deprecated; `%w` replaces it), and
  bare `return err` in functions that can fail several ways.
- Goroutines: confirm the spawned goroutine logs its own errors. Errors sent to
  a closed channel, or a dropped goroutine panic, are invisible without explicit
  logging inside the goroutine body.

**TypeScript / Node.js:**
- Preferred structured loggers: `pino` (lowest overhead, JSON by default, ideal
  for Lambda) or `winston` with a JSON transport. Flag `console.log` /
  `console.error` in production paths: CloudWatch Logs Insights cannot query
  unstructured output by field.
- Lambda: the logger must write to stdout or stderr (pino's default), and
  `requestId` should be bound at handler entry:
  `const log = logger.child({ requestId: context.awsRequestId })`.
- Promise rejection: check every `async` function for unhandled paths. A
  `.catch()` that only logs is often fine; `.catch(() => {})` or a missing
  `.catch()` on a fire-and-forget chain that can fail is CRITICAL.
- Next.js Server Components and Route Handlers: `console.error` works
  server-side but loses structure; prefer a shared pino instance.

**Swift (iOS / macOS):**
- Preferred API is `Logger` from OSLog (iOS 14+, macOS 11+). Flag `print()` in
  production code: it is not captured by the unified logging system and is
  stripped in release builds.
- Logger instances should declare a reverse-DNS subsystem
  (`com.myapp.networking`) and a category (`"API"`, `"Auth"`), which enables
  filtering in Console.app and `log stream`.
- Privacy: `Logger` redacts interpolated values in release builds unless marked
  `.public`. A value that must be visible in production (request ID, error code)
  needs `\(value, privacy: .public)`. Check that PII (names, emails, tokens) is
  NOT marked `.public`.
- `os_signpost`: new paths involving animation, image decode, or network
  round-trips benefit from `OSSignposter` intervals for Instruments. Absence is
  LOW, and only in performance-sensitive paths.

**Python:**
- Preferred structured logger is `structlog` (JSON or key-value, integrates with
  stdlib `logging`). Flag `logging.info("message %s" % val)`; use
  `log.info("message", key=val)` on a bound logger for queryable fields.
- Error chaining: `raise ValueError("context") from original_exc`. Flag a bare
  `raise ValueError("context")` inside an `except` block, which loses the
  original traceback.
- FastAPI / Lambda: confirm the request or correlation ID is extracted from the
  event and bound to the logger at handler entry.

---

## § FRESHNESS

Discovery, extraction, and scanning are in `resources/freshness.sh`; run it rather
than reimplementing them here. What stays judgment:

**Pick the oracle from the evidence, not from a default.** `DEP` records from a
manifest resolve against their registry or context7. `REF` records usually do
not: a Lambda runtime enum resolves against the AWS runtime support table, an
Anthropic model ID against the `claude-api` skill, a non-Anthropic model ID
(`openai.gpt-*`, `amazon.nova-*`, `gemini-*`) against that vendor's own
deprecation docs, since no local skill covers those and `claude-api` scopes
itself out when another provider is in play. A `PREREQ` is an availability
question, not a version race.

**Judge polarity before reporting a `REF`.** The same identifier appears in
prescriptions ("use `NODEJS_22_X`"), warnings ("`NODEJS_20_X` reached Lambda EOL
2026-04-30"), and history. Only the first is a finding. The script emits the
surrounding line so this is decidable without opening the file.

**A `COVERAGE GAP` is a finding about the review, not about the code.** It says an
ecosystem this project depends on was never examined, so "no CVEs" does not apply
to it. Report it under FRESHNESS with the cause the script gives, and treat it as
CONDITIONAL: the diff is safe to commit, the project's dependency picture has a
hole. The three causes want different recommendations.

- `no scanner extractor supports this ecosystem` is permanent and not the
  project's fault. CocoaPods is the current example. Say the graph is unaudited
  and move on; do not recommend a tool that does not exist.
- `no lockfile found for this ecosystem` is a real project gap. A manifest
  declares ranges and pins nothing, so there is nothing to check. Recommend
  committing the lockfile.
- `no osv-scanner installed` is environmental. Recommend installing it and say
  the pass ran blind, rather than reporting the fallback's single-ecosystem
  result as though it were the scan.

**Never read osv-scanner's `from N ecosystems` as coverage.** It counts the
ecosystems that had findings, not the ones that were scanned. A repo where Go, npm
and SwiftPM were all scanned and only npm was vulnerable reports "from 1
ecosystem", which reads exactly like a single-ecosystem scan. `SCANNED` and
`COVERAGE` are the coverage records; that line is a findings summary. Misreading
it is what hid a CVSS 8.7 advisory on regist.

**`FIX` records are the fix list; `SCAN` records are the evidence.** Prefer `FIX`
when writing the report: it is already grouped by the upgrade that closes the
advisories, so 21 findings read as roughly 10 decisions. Quote `SCAN` only when a
specific advisory needs naming. A `FIX` row carrying nine advisories is one
UPGRADE NOW line, not nine.

---

## § SIMPLIFY

Quality signals only. Anything that changes behavior belongs to BEHAVIOR AND
RISK, not here.

**Go:**
- An interface declared with exactly one implementation and no test double,
  especially one defined next to its implementation rather than at the consumer
- Struct fields written but never read, or left behind by a refactor
- A wrapper function that only forwards arguments unchanged
- `if err != nil { return err }` chains that a single `errors.Join` or an early
  helper would flatten
- Getters and setters on a struct whose fields could simply be exported
- A new `context.Context` parameter threaded through functions that never use it

**TypeScript:**
- A redundant type assertion (`as Foo`) where inference already gives `Foo`
- A barrel `index.ts` re-exporting symbols nothing imports
- A React component split into sub-components used exactly once, with props
  threaded purely to satisfy the split
- `useMemo` or `useCallback` around a trivially cheap expression, where the
  hook costs more than it saves
- A utility duplicating something already in the project's `lib/` or `utils/`.
  Grep before accepting a new helper
- An `any` or a widened type introduced to silence an error the shape could
  express properly

**Swift:**
- A protocol with one conforming type and no test double
- A computed property that only forwards to a stored one
- `guard let` chains that a single `if case let` or optional chain would express
- An extension adding a method used exactly once in the same file

**Python:**
- A class with one method and no state, which a function would express
- A wrapper around a stdlib call adding nothing but a name
- A comprehension nested deeply enough that a loop would read better
- `try/except` around code that cannot raise the caught exception

**All languages:**
- Comments explaining what the next line does, restating the code
- Comments narrating the change ("changed this to fix X"), which address the
  reviewer rather than the next reader and become noise once merged
- A feature flag or compatibility shim where the code could simply change
- Validation repeated at an internal boundary that a caller already enforced

---

## § GATE

What a project's validation entrypoint should contain, used to build the
recommendation behind the `no project validation entrypoint` finding. Recommend
only what the repo's own ecosystems justify: a checklist longer than the project
is a target nobody runs.

**Universal, whatever the language:**
- Every JSON and YAML file parses (`jq empty`, `yq`, or the language's parser)
- No merge-conflict markers survive in tracked files (`<<<<<<<`, `>>>>>>>`)
- No debugger or focused-test leftovers (`it.only`, `fdescribe`, `dbg!`,
  `binding.pry`, `breakpoint()`)
- The formatter agrees in check mode, so formatting never lands as diff noise
- Paths the build depends on resolve: scripts, assets, and doc links

**Go:** `go build ./...`, `go vet ./...`, `gofmt -l` returning empty, and
`go mod tidy` leaving `go.mod` and `go.sum` unchanged.

**TypeScript / JavaScript:** `tsc --noEmit`, the project's ESLint config, and
lockfile reproducibility (`npm ci` succeeds against the committed manifest).

**CDK TypeScript:** `tsc --noEmit` is the correct check for code-only changes.
Reserve `cdk synth` for PRs that add or move a Lambda or an asset path: synth
hashes build artifacts that a fresh checkout does not have, so wiring it into a
gate that must pass everywhere makes the gate fail everywhere.

**Swift:** `swift build`, plus SwiftLint or SwiftFormat in check mode when the
repo already carries a config.

**Python:** `ruff check` or flake8, `mypy` if the project is typed, and
`pytest --collect-only` so a broken import fails in a second rather than a suite.

**Rust:** `cargo check --all-targets`, `cargo fmt --check`,
`cargo clippy -- -D warnings`.

**AWS Lambda, any language:** grep the IaC sources for runtime and architecture
regressions, which reappear with every new construct and stay invisible until
deploy:
`grep -RnE 'NODEJS_(16|18|20)_X|Architecture\.X86_64'`, excluding
`node_modules`, `cdk.out`, `.next`, `dist`. Any hit fails the gate.

**Content, prompt, and plugin repos (markdown plus manifests):** a repo with no
compiler still has invariants, and they are checkable. Every manifest is valid
JSON against its schema; version fields that must agree do agree, verified in
both directions so neither list can drift unnoticed; every declared directory
exists and holds the file its convention requires; and any test scripts the repo
ships actually execute. This is the case most often mistaken for "nothing to
validate here."
