# Node: gate

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

Print `Gate: <command> (<green | N failures | none detected | not run>)`.

Run it to completion, in the background if it is slow, and keep reviewing
meanwhile. Give it up to 10 minutes. A gate that cannot finish is Built
NOT RUN, which makes the receipt CONDITIONAL: quality on small changes comes
mostly from the gate, so it is never skipped for speed.

Failures are findings: compile/type/lint under Built, failing tests under
tests. Quote the tool. Never paraphrase a compiler.

No entrypoint and no language default (a pure docs repo): Built is PASS with a
Follow-up item, MEDIUM, carrying a ready-to-paste target assembled from
`pass-reference.md` § GATE for the ecosystems present. Recommend it, do not
create it. A diff that removes or breaks an existing gate target is a counted
finding, not a repo-level gap.
