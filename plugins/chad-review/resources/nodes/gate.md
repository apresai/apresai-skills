# Node: gate

Runs in the real worktree (it has `node_modules`, `.env`, and build caches),
never in a `pr-stage.sh` worktree.

Discover the project's own validation entrypoint by evidence, first hit wins.
Never assume `make`.

- a Makefile target matching `^(validate|check|verify|ci)$`
- a `package.json` script named `validate` or `check`, or `lint` plus `typecheck`
- a `justfile` recipe or `Taskfile.yml` task of those names
- a `run:` step of `.github/workflows/*.yml` that is check-shaped (build, test,
  lint, typecheck, vet, audit). Never a step that deploys, publishes, releases,
  migrates, or pushes. If you cannot classify it from the name, skip it and say so
- failing those, the language default for the diff (`go build ./... && go vet ./...`,
  `tsc --noEmit`, `cargo check`, `swift build`)

**Read the recipe before running it.** A name is not evidence of what a target
does: `make validate` in one real repo runs a post-deploy script that probes
the production API and needs a cloud login. Read the Makefile recipe, the
`package.json` script, or the task body, and every script it calls. If it
deploys, publishes, migrates, pushes, or probes a live or production endpoint
(`curl` or an HTTP client against a non-localhost URL, a cloud CLI such as
`aws`, `gcloud`, or `az`), it is not a gate: print
`Gate: skipped <target> (<what it does>)` and fall to the next rule above.

Print `Gate: <command> (<green | N failures | none detected | not run>)`.

**Run it to completion, in the foreground, before any apply node starts.**
No time cap: quality on small changes comes mostly from the gate, so it is
never skipped or cut short for speed. Built is NOT RUN only when the gate
cannot be launched at all (its tool is missing, its command errors before
running anything); say why. NOT RUN makes the receipt CONDITIONAL.

Failures are findings: compile/type/lint under Built, failing tests under
tests. Quote the tool. Never paraphrase a compiler. They are tool evidence and
go to the ledger with ruling `TOOL`.

No entrypoint and no language default (a pure docs repo): Built is PASS with a
Follow-up item, MEDIUM, carrying a ready-to-paste target assembled from
`pass-reference.md` § GATE for the ecosystems present. It is a repo-level
decision, so the follow-up asks the user whether to add it, and never creates
it unasked. A diff that removes or breaks an existing gate target is a counted
finding, not a repo-level gap.
