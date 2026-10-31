# apply-deps: in-range dependency update

Used by `/deps-update` (and `/chad-review` pass 5). `/ultra-audit` never runs
it: review audits dependencies, it does not change them.

Only when the gate was green first and the blocked-packages check (below)
was clean first. If the gate was already red, print
`FRESHNESS | update skipped: gate already red` and stop. If the
blocked-packages check already hit before any update, print
`FRESHNESS | update skipped: blocked package already present` with the hit,
and stop: a hit on the starting tree is not the update's doing, so it cannot
be a reason to revert one.

Run `bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/freshness.sh"`
first if `freshness-audit` has not already run in this invocation. Then, for
each ecosystem root it discovered:

- **Go module**: `go get -u ./... && go mod tidy`. `go get -u` never crosses a
  major, because a Go major is a different import path.
- **npm, pnpm, or yarn package**: exact pins are the house rule, and
  `npm update` only moves within the range `package.json` declares, so on an
  exact pin it moves nothing. Rewrite the pins instead, with the updater
  pinned to an exact version:

  ```bash
  npx -y npm-check-updates@23.1.1 --target minor -u
  ```

  In a monorepo (a `workspaces` field in `package.json`, or a
  `pnpm-workspace.yaml`), run it once from the workspace root as
  `npx -y npm-check-updates@23.1.1 --target minor -u --workspaces --root`,
  which rewrites the root and every workspace `package.json`. `--target
  minor` takes the newest minor or patch within each dependency's current
  major, keeps an exact pin exact, and skips prereleases. Then install with
  the repo's own package manager so the lockfile it owns moves: `pnpm install`
  when `pnpm-lock.yaml` exists, else `yarn install` when `yarn.lock` exists,
  else `npm install`. A `0.x` dependency's minor is a breaking change by semver
  convention; the gate re-run is what catches it.
- **Another ecosystem with a native in-range updater**: use it. None: skip
  and say so.

These take the newest in-range releases, CVE fixes included.

**Snapshot first.** Before changing anything, `cp` to a temp dir every file
the update will touch: `go.mod` and `go.sum`; for Node, the root
`package.json`, every workspace `package.json`, and the lockfile. Never
`git checkout` to revert: that would also revert the user's uncommitted
manifest edits.

**The keep-or-revert unit** is the ecosystem root: one Go module, or one Node
project with its workspaces (they share one lockfile, so their manifests
cannot be kept or reverted one at a time). After the update, re-run the same
gate.

**Then the dependency checks**, after the update and before deciding keep:

- The blocked-packages check, the first of these that exists: the project's
  `check-blocked-deps` Makefile target (read its recipe before running it),
  then `scripts/check-blocked-deps.sh`, then `check-blocked-deps` on `PATH`
  as the last fallback. None: say so in the report. The same check ran clean
  before the update, so a hit now means the update brought the blocked
  package in: revert that root as below and report the hit.
- osv, by re-running `freshness.sh` (it runs osv-scanner).

**Green** (gate green, no blocked-package hit): keep. Report each moved dep
as `old -> new`. Leave the files uncommitted. Majors still held back are one
informational line, not findings.

**Red** (gate red, or a blocked-package hit): restore that root's files from
the snapshot, then re-run the same install command (Go needs nothing more)
so `node_modules` matches the restored lockfile again; without the reinstall
the next gate would still test the new versions. Report the failing output
by caller:

- `/deps-update`: one NEEDS-DECISION item naming the root, the versions that
  were attempted, and the failing gate output or blocked package. It goes in
  the report and in the deps PR body, and it is reported even when nothing
  else moved.
- `/chad-review` pass 5: a HIGH finding, as that command's pass 5 says.
