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

Print `Gate: <command> (<green | N failures | none detected | over budget>)`.
Cap around 60s. Past that, report over budget and continue.

Failures are findings: compile/type/lint under Built, failing tests under tests.
Quote the tool. Never paraphrase a compiler.

No gate at all is a Built finding, MEDIUM, with a ready-to-paste target assembled
from `pass-reference.md` § GATE for the ecosystems present. Recommend it, do not
create it. It does not by itself fail Built for an unrelated typo (leaf), but
report it.
