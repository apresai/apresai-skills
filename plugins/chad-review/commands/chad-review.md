---
name: chad-review
description: 5-pass pre-commit code review (drift, behavior and risk, tests, observability, dependency freshness). Use when the user asks for a pre-commit review, says "review before I commit" or "review the last commit", or invokes /chad-review. Reviews uncommitted changes, else the last commit. Emits the receipt that receipt.sh verify checks at the merge gate.
---

# Chad Review: 5-Pass Code Review

Autonomous review of uncommitted working-tree changes, or the last commit if the
tree is clean.

**This skill is not read-only, and calling it read-only has been wrong.** It
never edits the change under review, never commits, and never applies a fix to
the code it is reviewing, and those three are real invariants. It makes exactly
one edit of its own: pass 5 updates dependencies in place (in-range native
update commands, kept only if the gate re-runs green, reverted otherwise, never
committed). Beyond that, doing its job means executing the project's
own commands: its gate, its tests, its codegen, its linters, its vulnerability
scanner. Those write to disk. `go mod tidy` rewrites manifests, `npm ci` rewrites
`node_modules`, a formatter in a `validate` target rewrites source, and a
generator rewrites generated files. The sub-agents additionally hold Bash, Edit,
and Write, so even "never edits" is enforced by prompt wording rather than by
tool restriction.

Treat it as a skill that runs your build. If a command in your test, gate, or
codegen path has side effects you would not want a reviewer triggering, that is
a real exposure, not a theoretical one.

Each pass answers one distinct question, so no defect is reported twice:

| Pass | Question | Owner |
|---|---|---|
| 1. DRIFT | Two things that should agree, don't | reviewer agent |
| 2. BEHAVIOR AND RISK | What changed, and what breaks it | agent + parent |
| 3. TESTS | Do affected tests pass, and do tests exist | parent + agent |
| 4. OBSERVABILITY | Debuggable in production without a repro | reviewer agent |
| 5. FRESHNESS | Deps updated in range, CVE-free, not end-of-life | parent |

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

   **Back up untracked files first.** The skill's no-edit rule is enforced by
   prompt wording, not by tool restriction: the reviewer agents are
   `general-purpose`, holding Bash, Edit, and Write, and
   the review runs the project's own gate, test, and codegen commands, which
   write to disk by design. On 2026-06-14 a
   review sub-agent "restored" the tree with a git command that sweeps untracked
   files; an untracked test file under review was gone from disk afterwards while
   the review reported success. Any of those paths can do it, so back them up on
   every working-tree review, including the `light` shape.

   **Only when step 1 actually listed a `??` entry.** With no untracked files
   there is nothing for the guard to protect, and a file that appears later is a
   new artifact rather than a finding, which is how Phase 2 step 6 already treats
   it. Skipping is not a shortcut around the safety property: it is declining to
   back up the empty set, on the evidence `git status --porcelain` just produced.
   Say so in the header (`Untracked guard: not needed, 0 untracked files`) and
   skip the matching verify in Phase 2 step 6. On a clean-tree last-commit review
   this is always the case.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/untracked-guard.sh" backup
   ```

   It prints the backup path; **put that path in the report header** so the files
   are recoverable even if this session dies. A non-zero exit means something
   could not be backed up: stop and tell the user rather than reviewing an
   unprotected tree. That includes exit 127 on an install predating the script
   (unlike `chad-review-route.sh`, this one has no fallback and is not meant to
   have one: routing degrades to a worse default, but skipping the guard silently
   drops the only thing standing behind the no-edit rule).

3. **Announce the target and tier** in one line, mapping your session model per
   §"Model tiering":
   `Chad Review: working tree (2 staged, 3 unstaged, 1 untracked), opus session, LOOKUP=haiku REVIEW=sonnet JUDGE=opus`
   If the session model is undeterminable, use the `unknown` row and say so.
4. The diff feeds passes 1, 2, 3 (coverage), and 4. The changed files list
   drives test selection. Pass 5 is whole-project: it audits and updates
   dependencies regardless of the diff, reading the file list only to tag.
5. **Route by language family:**

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

   Markdown routes three ways, exec winning first: executable prompt content
   (its own `general-purpose` reviewer), **status-bearing docs** (a changed doc
   whose FULL contents carry lifecycle or operational-value markers, or whose
   change is substantial: its own `general-purpose` reviewer at REVIEW tier,
   reading complete files plus the `docs-drift.sh` records), and trivial prose
   (no reviewer; the parent covers it). Whenever any markdown changed, routing
   also emits a `DOCS-DRIFT-TASK` line: that is the parent's own executable
   DRIFT step (see `[docs/status]` and `[docs/live-value]`), run the way
   `freshness.sh` is run, not routing commentary.

   **Mixed-language diffs**: spawn ONE reviewer per block. **Scope the diff per
   block**: each reviewer sees ONLY that language's hunks. DRIFT's
   codebase-wide grep is scope-independent, and the parent still sees everything.
   All findings merge into one report.

   If the script is missing, fall back to the picks in §"Execution strategy".
6. **Classify the diff shape.** Ambiguity always falls to `standard`.

   Routing runs first on purpose: step 5 already walked and classified this exact
   file list, so read its `Files detected:` block instead of re-walking it. The
   one thing it does not give you is the changed-line count, and that came from
   the `--stat` in step 2.

   - `light`: **docs-only** (`*.md`, `*.txt`, `docs/**`, LICENSE, images),
     **config-only** (`.github/**`, `.gitignore`, `.editorconfig`, linter
     configs; not manifests, not IaC), or **tiny** (at most 4 files AND at most
     40 changed lines of non-test production code).
     **Forced to `standard` regardless**: `CLAUDE.md`, any `*/SKILL.md`,
     anything under `.claude/`, a `prompts/` dir, or a plugin's `commands/`,
     `agents/`, or `skills/` dir. Here those are executable behavior, not prose.
     **Docs-only qualifies as `light` ONLY when routing emitted no
     `Docs / status-bearing` block.** A status-bearing doc forces `standard`,
     which naturally fans out to just that one sonnet reviewer plus the parent;
     a typo fix in ordinary prose stays light-inline.
   - `deps`: only manifests and lockfiles (`go.mod`/`go.sum`, `package.json` +
     lockfile, `pubspec.*`, `Package.swift`/`Package.resolved`, `Cargo.*`,
     `pyproject.toml`/`requirements*.txt`).
   - `standard`: everything else.

   | Shape | Agents | Treatment |
   |---|---|---|
   | `light` | 0 | Every pass runs INLINE in the parent; a small or prose-only diff does not justify an agent bootstrap. Because no reviewer fans out, the parent is the author, so its findings still go to the Phase 2 step 4 verifier (one JUDGE-tier agent) and the report carries the `Verified:` line as usual. On docs-only the doc is the subject, so DRIFT leads (accuracy against the code, staleness) and BEHAVIOR AND RISK is a quick probe for secrets, PII, or wrong commands. On config-only, CI and workflow changes ARE behavior: probe them properly (a `pull_request_target` trigger running untrusted PR code with secrets, a permissions widening, a cache-poisoning path). FRESHNESS runs in the parent regardless of shape: the script, then the in-range update per §5. |
   | `deps` | 0 | FRESHNESS runs in the parent, every dep tagged `(diff-touched)`. TESTS runs in the parent, since bumps break tests. Others: one-line inline notes or N/A. |
   | `standard` | 1 per language block + 1 | Full fan-out per §"Execution strategy". |

   Print `Diff shape: <shape>`. When it is not `standard`, add "rerun with
   `/chad-review --full` to force the complete fan-out". `--full` skips
   classification and treats the diff as `standard`.
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
   - a `run:` step of `.github/workflows/*.yml`, but **only a check-shaped one**
     (build, test, lint, typecheck, vet, audit) and never one that deploys,
     publishes, releases, migrates, or pushes. CI steps run with different
     assumptions than a review does, and executing one blind is how a code
     review ships a release. Anything you cannot classify from its name, skip
     and say you skipped it
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
(`*.generated.{ts,go,swift,kt}`, `*.gen.go`, `*.gen.ts`, `*_gen.*`,
`generated/`, `**/types/api.*`). Changes after regeneration mean the committed
types are stale.

**`[types/mirror]` Reverse generated-contract reconciliation.** The check
above proves the generated artifact is fresh; it is structurally blind to the
opposite rot, a HANDWRITTEN twin of a definition the generator now covers,
kept alive by a comment claiming the generated file "predates" it. Run the
deterministic scanner (seconds, whole-project by design: the stale mirror is
by definition outside the diff):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/contract-mirror.sh"
```

A `MIRROR` record (a handwritten declaration whose name a generated contract
also defines) is **HIGH**, and **CRITICAL** when the diff touched either side
of the pair. A `STALECOMMENT` record (predates / not-regenerated /
hand-written-here language near a mirror) corroborates and is HIGH on its own
when it names regeneration debt. `SUMMARY gen_files=0` reports as
`N/A - convention not detected`. Never re-implement this scan with ad-hoc
greps; record grammar and judgment guidance: `pass-reference.md`
§ `[types/mirror]`.

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

**`[docs/status]` `[docs/live-value]` Documentation self-consistency.** The
check above looks outward from the code change; these two look INTO the
changed docs themselves, whole files, not just changed lines. This is an
executable task, not a judgment call: run the `DOCS-DRIFT-TASK` command from
the routing output (equivalently, `resources/docs-drift.sh`, plus
`--last-commit` in that mode), the same way `freshness.sh` is run.

- **HIGH** `[docs/status]`: a `CONTRA status-conflict` record. The doc carries
  a historical banner AND still calls itself active or the working plan; it
  lies about its own lifecycle. A `CONTRA index-conflict` is the same defect
  split across files: an index classifies the doc one way, the doc says the
  other.
- **HIGH** `[docs/live-value]`: a `STALE` record in live instructions. A
  version floor ("build 117/118 or later", "131+") below the authoritative
  value; the record quotes the authority value and its source file, so quote
  both. Clearly labeled historical sections, dated evidence lines, and
  wholly-historical files are preserved, never flagged: the script suppresses
  them deterministically, and a snapshot that says build 117 WAS current is
  history, not drift.
- `MARKER` and `INDEXED` rows are evidence needing judgment, the FRESHNESS
  `REF`-polarity discipline: read them, do not auto-report them. `OKDOC`
  present means scanned-clean; `OKDOC` absent means NOT scanned, and the two
  are never conflated.

Record grammar, marker classes, authority precedence, and the four
suppressions: `pass-reference.md` § `[docs/status]` `[docs/live-value]`.

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

Nothing this project depends on is unsafe, dead, or behind where its own
manifest ranges allow it to be. Whole-project: it runs regardless of what the
diff touches, and the changed-files list is read only to tag `(diff-touched)`.

**Run the audit.** Everything mechanical lives in the script: manifests, direct
dependencies, runtime constraints, version-bearing references in files that are
not manifests, undeclared prerequisites, and the vulnerability scan.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/freshness.sh"
```

Five ways its output can be misread, and no others:

- **`REF` records need polarity judgment, which is why each carries its line.**
  "`NODEJS_20_X` reached Lambda EOL 2026-04-30" is a correct warning. Flagging it
  is a false positive; so is suppressing the prescription sitting next to it.
- **`SCAN none` is not clean.** It means no scanner is installed. Report the gap.
- **N/A needs a `SUMMARY` with zero manifests, zero refs, and zero prereqs**, and
  it is reported with those counts: `N/A - scanned <N> files, no version-bearing
  references`. "No manifest found" is an allowlist miss, not a conclusion.
- **osv-scanner's `from N ecosystems` is a findings count, not a coverage
  count.** It counts ecosystems that had vulnerabilities. Coverage lives in
  `SCANNED` and `COVERAGE`. Reading that line as coverage is what hid a CVSS 8.7
  SwiftPM advisory on a real repo while the review read as complete.
- **`ecosystems=` and `scanned_ecosystems=` differing is the headline, not a
  detail.** Any `COVERAGE ... GAP` means part of this project's dependency graph
  was never examined, so "no CVEs" does not cover it. Report every GAP with the
  cause the script states.

Prefer `FIX` records over raw `SCAN` lines when writing the report. They are
already grouped by the upgrade that closes them, so one row can carry nine
advisories and becomes one line rather than nine.

**Then update the dependencies.** Not classify, not offer: update. The native
tools stay in range on their own: `npm update` moves only within the ranges
`package.json` declares, and `go get -u` never crosses a major (a Go major is a
different import path). Take the newest in-range releases, CVE fixes
included (`resources/nodes/apply-deps.md`). For each manifest the script
discovered:

- Go module: `go get -u ./... && go mod tidy`
- npm package: `npm update`
- Another ecosystem with a native in-range updater: use it. None: skip it and
  say so in the report.

The update runs in Phase 2, after the tests have run on the user's change alone
(so a failure attributes cleanly), and before the receipt is emitted (so the
fingerprint covers the updated tree). **Only when step 1 and the pre-flight
gate were green**: on a tree that is already failing, the re-run below cannot
attribute anything, so skip the update and report one line,
`FRESHNESS | update skipped: gate already red`. **First snapshot every
manifest and lockfile** the update will touch (`cp` to a temp dir): the revert
path must restore the pre-update state, and on a working-tree review those
files can carry the user's own uncommitted edits, which `git checkout` would
destroy along with the bumps. Then update, and re-run the same gate pre-flight
step 7 ran:

- **Green**: keep the updates. Report each moved dep as `old -> new`, plus one
  informational line naming majors still held back (straight from
  `npm outdated` / `go list -m -u ...`): they are out of range by the manifest's
  own choice, not findings and not backlog. The updated manifests and lockfiles
  stay uncommitted; the report tells the session to land them as their own
  `deps:` commit. The skill still never commits.
- **Red**: restore the failing package's manifests and lockfiles from the
  pre-update snapshot (never `git checkout`, which would also revert the user's
  own uncommitted manifest edits), and report the failing output as a HIGH
  finding. The unit of keep-or-revert is the manifest, not the run: in a
  multi-package repo each package's update stands or falls with its own gate,
  so green packages keep their updates while a red one reverts (proven on the
  first live run: a cdk-opennext patch broke one package's typecheck while the
  Go and web updates were green). No per-dep bisect within a manifest;
  whatever pins that package to a stale in-range version is real work for the
  session that picks up the finding.

**What is left after updating takes exactly the judgment this pass exists to
hold.** Sort every remaining item into a tier; naming the tier is what stops
these from all being routed to the user:

- **A direct production dependency blocked by breaking changes** (a held major
  on a runtime/product dep, a red-gate revert, or a CVE whose fix crosses a
  major). Production vs dev-tooling is decidable from the manifest, not the
  script: `dependencies` vs `devDependencies` in package.json, and for Go
  whether shipped code imports it (freshness.sh does not mark this; read the
  manifest). Judge the breakage itself first. **Trivial and mechanical** is
  not a decision: the failing output names the exact lines and the fix changes
  no runtime behavior (a type guard, a rename, an import move); when in doubt
  it is NOT trivial. Mark it `fix-and-take-now` with the concrete fix; the
  session applies it right after this review as its own change through the
  normal pipeline, its own commit or PR with its own review, never folded
  silently into the change under review, and the review itself still edits
  nothing beyond the §5 update step. **Real breaking surface** gets a decision
  block: current -> target, what concretely breaks (the gate output when the
  update was attempted, the changelog's breaking surface when it was not), and
  a proposed path. In an interactive session, ask the user with that data in
  hand; as a sub-agent or headless, mark it NEEDS-DECISION. Dev-tooling majors
  (devDependencies, linters, test runners) stay on the one informational
  held-majors line, nobody needs a decision block for eslint, with one
  promotion: a CVE moves a dev-tooling dep into this bullet's full judgment.
- **A transitive or bundled dependency inside a well-known library** (the AWS
  SDK's internals, a dep bundled in aws-cdk-lib): warn, never block, never
  NEEDS-DECISION. Say what it is, why it is unreachable (bundled, pinned by
  the parent), and when it resolves (the parent's next release). A CVE here
  keeps the same framing with its severity attached: be aware, not actionable
  here, watch the parent. It never moves the verdict.
- **An end-of-life runtime or unsupported framework major**: CRITICAL. These
  are direct and actionable, and severity is the point.
- **A `COVERAGE ... GAP`**: report with the cause the script states, as before.

One line each as
`FRESHNESS [security|eol|fix-and-take-now|decision|bundled|coverage] | <dep or ecosystem> | <=15 words`,
with each decision block directly under the line that summarizes it. `security`
tags any direct-dep CVE line whatever tier resolves it; a bundled CVE stays
tagged `bundled` with its severity in the line.

Clean means "every in-range update applied or none needed, no CVE, no
end-of-life runtime, **and every discovered ecosystem actually scanned**". The
last clause is not decoration: without it the honest output for a repo whose
Swift graph was never opened is indistinguishable from a clean one, which is the
failure this pass shipped with.

A CVE or EOL on a direct dependency the diff touched is NO-GO. Pre-existing and
untouched on a direct dependency is CONDITIONAL: this change is safe, the
project is not. A bundled or transitive advisory, CVE included, is advisory
only and never moves the verdict. Everything else is advisory.

## Execution strategy

### Model tiering (session-relative)

**ALWAYS pass an explicit `model` on every Agent launch.** This is load-bearing:
since Claude Code v2.1.198 a launch with no explicit `model` silently inherits
the parent session tier.

Three tiers, and the expensive one is deliberately the smallest.

| Tier | Steps | Model |
|---|---|---|
| **LOOKUP** | version lookup for DEP records | `haiku` |
| **REVIEW** | the per-language reviewer that reads the diff and raises findings | `sonnet` |
| **JUDGE** | the parent's attack probes, and the Phase 2 step 4 verifiers | `opus`, at `effort: high` |

| Session model | Parent | LOOKUP | REVIEW | JUDGE |
|---|---|---|---|---|
| opus | opus | haiku | sonnet | opus |
| sonnet | sonnet | haiku | sonnet | opus |
| fable | fable | haiku | sonnet | opus |
| unknown / haiku / other | = session | haiku | sonnet | opus |

JUDGE is opus in every session, a sonnet one included: the verifier decides
which findings get fixed, and a weaker verifier checking stronger work is the
weakest arrangement measured. A fable session keeps only the orchestration shell on fable.

**Haiku is correct for LOOKUP and wrong everywhere else.** The line is whether
the step decides something about the code. Reading a version out of a registry
is not a decision. Raising a finding is, and so is ruling on one: haiku used to
score findings here, and that score decided what got dropped.

**The reviewer is `sonnet` here, `opus` in `/ultra-audit`.** `/chad-review` is
the cheaper explicit fan-out. The default pre-merge review, `/ultra-audit`, runs
every reviewer on opus at `effort: high`; Anthropic's current code-review plugin
also moved its bug finders and validators to opus. Both tools verify every
finding at JUDGE tier.

**Never spawn fable**: at 2.5 times the Opus rate it buys no review
advantage here. `opus`, `sonnet`, and `haiku` are aliases resolved at spawn time;
never hardcode a dated model ID. Pricing snapshot 2026-10-31: Opus 5.5 $4/$20 per
MTok, Sonnet 5.5 $2/$10, Haiku 5.5 $0.10/$0.50 (prompts up to 100K tokens),
Fable 5.1 $10/$50.

### Effort

The Agent tool once exposed `model` but no `effort` parameter (verified on Claude
Code 2.1.220). That is no longer true: the Agent tool now takes `effort`, and
may use it when a skill explicitly asks. This skill asks for `effort: high` on
every JUDGE-tier verifier launch, since Opus 5.5 defaults to `medium`.
Reviewers inherit the session effort. `/ultra-audit` sets `high` on every agent
it launches.

### Phase 1: fan out

Launch **one reviewer per language block**, in ONE message, so a
single-language diff is 1 Agent tool use and CDK plus Go is 2.

**Reviewer** owns passes 1, 2 (what changed), 3 (coverage only), and 4, at the
REVIEW tier (sonnet). `subagent_type` is `general-purpose` for every block, as
the routing script emits it: a reviewer that reports everything with a
confidence, so the Phase 2 verifier is the only filter. Routing still decides
which hunks, codegen hint, and Context7 docs each block gets. It reads the diff once
and emits each pass as its own labeled section, which is what keeps the
five-heading invariant intact. It needs tool access to run generators, spec
validators, and route-parity tests for DRIFT.

The **status-bearing docs reviewer** is one of these blocks when routing
emitted it: `general-purpose`, REVIEW tier, and its prompt carries the
`docs-drift.sh` records plus an instruction to read the flagged docs in FULL,
since the contradiction is rarely inside the diff hunks.

**FRESHNESS** runs in the parent and spawns nothing: `freshness.sh` does the
whole audit in a few seconds, and in one on a small repo. Measured at 6s on a
4,900-file repo with three ecosystems, most of it the two scanner round trips.
Version resolution needs no agent either: the update commands and
`npm outdated` / `go list -m -u` answer it mechanically in Phase 2 step 2.

Wait for all Phase 1 results before proceeding.

### Phase 2: the parent pass

One pass, holding every finding at once:

1. **Run the tests.** Do not delegate: run them directly so output streams to the
   user and the parent has full context to propose fixes.
2. **Update the dependencies** (pass 5's update step): run the in-range
   updates, re-run the gate, keep or revert per §5. This is the skill's one
   sanctioned edit of its own, and it sits here on purpose: after step 1, so a
   test failure attributes to the user's change and not the bumps, and before
   step 8, so the receipt's fingerprint covers the updated tree.
3. **Attack** (BEHAVIOR AND RISK, attack half) with targeted grep and file reads
   to confirm edge cases. This is JUDGE-tier work: inline when the parent is
   already there (opus and sonnet sessions), otherwise delegate this step alone
   to one JUDGE sub-agent.
4. **Verify every finding adversarially.** Follow
   `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/nodes/verify.md`
   exactly: JUDGE-tier (`opus`, `effort: high`) verifiers that did not write the
   findings, grouped by file up to 5 per verifier, all launched in one message.
   Each finding is CONFIRMED, PLAUSIBLE (the default when the verifier cannot
   construct the state), or REFUTED, and REFUTED only with quoted code or a
   command and its output that disproves it. Script-sourced findings skip
   verification: they are already evidence.

   This replaced a confidence-80 filter in 3.0.0. That filter put the burden on
   keeping a finding, scored by haiku, and it dropped real defects that nobody
   had disproved; self-reported confidence is not calibrated well enough to cut
   on. Disproving now carries the burden.

   Emit one `Verified: N raised, C confirmed, P plausible, R refuted` line, and
   list each REFUTED finding with its evidence.
5. **Mark PRE-EXISTING findings.** A finding on a line the diff did not touch,
   on behavior the diff does not reach, is reported under `Not blocking` and is
   not counted. Everything else that survived step 4 is counted.
6. **Confirm the working tree survived.** Skip this only when pre-flight step 2
   skipped the backup because there were no untracked files; there is nothing to
   verify, and the header already says so.

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
7. **Write the verdict.**
8. **Emit the receipt.** Every completed review emits one, whatever the
   verdict: a NO-GO receipt records that the review happened and forces the
   fix-then-re-review loop, and `verify` fails it at the gate.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/receipt.sh" emit \
     --verdict <GO|NO-GO|CONDITIONAL> --counts critical=N,high=N,medium=N,low=N
   ```

   It prints the receipt path; put that path on the report's `Receipt:` line.
   If a PR for this branch already exists (`gh pr view --json number`
   succeeds), add `--pr <n>` so it publishes to the PR immediately; otherwise
   state in the report: after `gh pr create`, run `receipt.sh publish`, and
   before `gh pr merge`, run `receipt.sh verify --pr <n>`.

   The receipt binds the verdict to the exact content reviewed: head SHA plus
   a stable diff fingerprint (`git patch-id --stable` over the merge-base
   diff, untracked files folded in). At the merge gate the exact reviewed
   head passes, a clean rebase with an unchanged diff converges on the
   fingerprint, and any substantive diff change fails closed. After fix
   commits, the convergence rule reviews only the fix delta, but the receipt
   is always re-emitted at FULL scope for the new head and fingerprint;
   `verify` trusts the newest ruling for the current content, so a stale GO
   can never outlive the diff it reviewed.

### Writing sub-agent prompts

The prompt contract (what every sub-agent prompt must contain, the verbatim
output contract, the prompt skeleton, and the Agent call shape) lives in
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/fanout.md`.

Read it when you are about to launch an agent, and only then: `standard` shape.
`light` and `deps` spawn nothing and never need it, and `light` is the common
case.

## Performance budget

Target: under ~2 minutes for a typical single-language change (5 to 10 files),
`light` and `deps` well under a minute.

The levers in order of size: the diff-shape matrix skips the fan-out entirely for
most everyday changes; the scripts (`freshness.sh`, `chad-review-route.sh`,
`docs-drift.sh`, `contract-mirror.sh`, `receipt.sh`) do in seconds what an agent
would take a bootstrap to do, so like `freshness.sh` they are never skipped for
budget; the deterministic gate catches mechanical defects before an agent is
asked to look for them; and a two-agent fan-out means wall-clock is the slowest
agent, not the sum.

Running long, cut in this order:

1. **FRESHNESS**: the update commands cost seconds; if the gate re-run is the
   budget problem, scope it the way lever 3 scopes TESTS. NEVER skip
   `freshness.sh` itself: a CVE or EOL runtime is CRITICAL and the script costs
   a few seconds.
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
| About to commit or push; the default full adversarial review whose receipt satisfies the merge gate | `/ultra-audit` |
| Want the fixed 5-pass fan-out, a GO / NO-GO / CONDITIONAL verdict, and a fix prompt | `/chad-review` |
| Quality-only cleanup, applied, **before** the gate | `/simplify` (built-in) |
| Quick read of one file or a change under three files | `/review` (built-in) |
| Code already in a GitHub PR; want inline PR comments and CI context | `pr-review-toolkit:review-pr` |

Both review tools run before the commit; pr-review-toolkit is for after the PR
is open. `/simplify` runs before the review, never after: applying edits after the
gate mutates the reviewed diff and re-arms it. The cycle is build, test,
`/simplify`, `/ultra-audit` (or `/chad-review`), PR, then
`receipt.sh verify --pr <n>` immediately before the merge: the merge gate
checks the receipt, not the session's memory of a review, and either tool's
receipt satisfies it.

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
[updated deps (old -> new) + FRESHNESS tag lines (security, eol, fix-and-take-now, decision, bundled, coverage) + decision blocks, or "Clean"/"N/A"]

Verified: N raised, C confirmed, P plausible, R refuted

### Verdict: [GO / NO-GO / CONDITIONAL]
[1-2 sentences: commit as-is, fix something first, or stop and rethink]

Receipt: <path, or "published to PR #N">
```

Carry each finding's wording verbatim. Step 4 may adjust a severity or
sharpen a `file:line`, and those edits carry through; nothing else is rewritten.
**Replace the confidence score with the ruling** (CONFIRMED or PLAUSIBLE). A
PLAUSIBLE finding states what would confirm it.

**Verdict mapping.** GO only when no counted finding remains at any severity.
Any counted finding is NO-GO: severity decides fix order, never whether a fix
happens. `receipt.sh verify` fails a GO whose counts are not all zero. Also **strip any process narration** an agent emitted
despite the contract. Findings in the deliverable, never the process.

**How FRESHNESS affects the verdict.** Being whole-project and always-on, a
pre-existing dependency issue unrelated to the diff should not hard-block an
unrelated commit:

- **CRITICAL on a direct dependency the diff touched or introduced: NO-GO.**
- **CRITICAL that is pre-existing and untouched, on a direct dependency:
  CONDITIONAL**, with a prominent callout. This change is safe to commit; the
  project carries a CRITICAL issue to schedule now.
- **A bundled or transitive advisory, CVE included: never moves the verdict.**
  It is a warn line in the FRESHNESS body, full stop. Escalating one of these
  to CONDITIONAL is the failure the bundled tier exists to prevent.
- **Any `COVERAGE ... GAP`: CONDITIONAL**, never a silent GO. An unscanned
  ecosystem is not a clean one, and the failure this guards against is a review
  that reads as complete over a dependency graph it never opened. It does not
  hard-block, because the usual cause is environmental rather than a defect in
  the diff. State the ecosystem and the cause in the verdict line itself, not
  only in the FRESHNESS body.
- **A reverted package's update (its gate went red): HIGH**, naming the
  package and carrying the failing output, then judged by the tier rules: a
  trivial mechanical fix is `fix-and-take-now`, real breaking surface is a
  decision block.
- **Applied updates and `fix-and-take-now` items: never in the verdict.**
  Applied updates appear in the report and the `deps:` commit instruction;
  fix-and-take-now items are work the session does right after the review.
  Dev-tooling majors held back are one informational line, not backlog.
  FRESHNESS decision blocks (a major held back) are asked interactively or
  marked NEEDS-DECISION and are informational: they are not counted. A
  NEEDS-DECISION finding about the diff itself is counted until decided.

## After the report: fix prompt

Offer a copyable **fix prompt** when the verdict is NO-GO or CONDITIONAL. Keep it proportional; no filler. It must:

1. **List every finding needing action**, with pass, severity, file, and lines.
2. **Describe the outcome of each fix**, not the implementation ("ghost.go should
   use Eastern time for the race date, matching how live races work").
3. **Point at existing patterns** in this codebase that already do it right.
4. **Fix all of them, in this change.** Every counted finding blocks the merge
   at every severity; order the list by severity so the worst is fixed first.
   A finding the author thinks is wrong is dismissed only with a quoted
   `file:line` or a command and its output, carried into the re-review. One exception: a FRESHNESS CRITICAL the diff did not
   touch is listed under required fixes labeled "schedule now, does not block
   this commit".
5. **End with the loop that closes it**: apply the fixes, then run
   `/chad-review` again to confirm. Any cleanup pass (`/simplify`) runs before
   that re-review, never after it, per §"Choosing between review tools".

Then: ask "Want me to enter plan mode with this prompt, or do you want to edit it
first?" ONLY when the verdict is NO-GO or CONDITIONAL AND this is a direct
interactive session; enter plan mode with the prompt (or the user's edited
version). On a GO, print the report and end the turn without asking. As a
sub-agent, inside another skill (`/wrapup`), or headless, never block on a
question: the fix prompt is already in the report body.

## Rules

- NEVER edit a source file, commit, or apply a proposed fix. Show it only. Two
  exceptions, both bounded: Phase 2 step 2 updating dependency manifests and
  lockfiles (kept only on a green gate re-run, reverted otherwise, never
  committed), and Phase 2 step 6 restoring a file that vanished during the
  review, which puts the tree back as it was rather than changing the diff.
- **The no-edit rule is not a read-only guarantee, and it is not tool-enforced.**
  Sub-agents hold Bash, Edit, and Write, and the review runs the project's own
  gate, tests, and codegen, all of which write to disk. A `git stash -u`,
  `git clean`, or `git checkout` from any of those destroys untracked files under
  review. That is why pre-flight step 2 backs them up and Phase 2 step 6 verifies they
  survived: the guard exists precisely because the guarantee does not.
- **Run checks, not actions.** Every command this skill triggers must be one that
  inspects: build, test, lint, typecheck, generate-and-diff, scan. Never run a
  target that deploys, publishes, releases, migrates, or pushes, even when it
  appears in the project's own gate or CI workflow. When a discovered command's
  effect is not obvious from its name, do not run it: report it as undetermined
  and say what you skipped.
- Never silently skip a pass. All five appear as headings in every report. A pass
  may return early per the shape matrix, but only with the explicit line
  "N/A - not applicable to this diff shape (<shape>)". The same holds one level
  down: an absent convention says `N/A - convention not detected` rather than
  vanishing.
- ALWAYS pass an explicit `model` on every Agent launch, per §"Model tiering".
  Haiku is correct for LOOKUP and wrong above it; never fable.
- **The prescribed agents are the entire budget**: one reviewer per routing
  block (language blocks and the status-bearing docs block alike), and the
  Phase 2 step 4 verifiers. The verifiers are the one sanctioned exception to
  "no agent checks another agent": they are JUDGE tier, batched up to 5
  findings each, and independence from the author is the whole point of them. Never spawn a second agent for work one can finish.
- **Never spawn an agent to find out whether there is work.** Sub-agents do
  bounded work whose shape is already known. If a deterministic command in the
  parent answers the question, the parent answers it and passes the result down.
  A launch costs roughly 70k tokens before the agent reads a single line, almost
  all of it tool schema and brief, so an agent that returns "nothing to do" spent
  the entire bootstrap to deliver a fact a `find` would have produced for free.
  It is why FRESHNESS, routing, and the gate are scripts rather than paragraphs.
- DRIFT may run type generators, spec validators, and route-parity tests. These
  are non-destructive.
- If the diff exceeds roughly 50 files or roughly 3000 changed lines, ask whether
  to scope the review to specific directories. The line count is the better
  signal on a repo of large files; the file count is the better signal on a wide
  refactor, so either trips the question.
