# Node: apply-deps (freshness-update)

Only when this node is listed and the pre-flight gate was green. If the gate
was already red, print `FRESHNESS | update skipped: gate already red` and stop.

Run `freshness.sh` first if `freshness-audit` has not already run in this
invocation. Then, for each manifest it discovered:

- Go module: `go get -u ./... && go mod tidy`, then apply the release-age floor
- npm package: `npm update --before="$FLOOR"`
- Another ecosystem with a native in-range updater: use it, then apply the
  floor by hand. None: skip and say so

Snapshot every manifest and lockfile the update will touch (`cp` to a temp
dir) before changing them. Never `git checkout` to revert: that would also
revert the user's uncommitted manifest edits. Restore from the snapshot if
the gate re-run is red. Keep-or-revert is per manifest.

## Release-age floor

Take a version only once it has been published for 14 days.
`FLOOR=$(date -v-14d +%F 2>/dev/null || date -d '14 days ago' +%F)`.

- **Trusted publishers** are exempt: a package on the trusted-publisher list
  in the project's or user's `CLAUDE.md` (Dependencies section) may be taken
  the day it ships, newest stable within its current major. No list found
  means no exemptions. For npm, run `npm update <trusted pkgs>` without
  `--before` after the floored update.
- **Go** has no `--before`. Capture `go list -m all` before and after
  `go get -u`. For each moved module that is not trusted, read the release date
  with `gh release view <new version> --repo <owner/repo> --json publishedAt`.
  `go list -m -json` `.Time` is commit time, which a tag can backdate, so it is
  not proof of age. Younger than 14 days, no GitHub release, or not hosted on
  GitHub: `go get <module>@<old version> && go mod tidy`.
- Report each version the floor held back as one line with its eligibility
  date (publish date plus 14 days), or `age unverifiable, needs a waiver`.
- **A CVE fix younger than the floor is never taken automatically.** When a
  held version is the fix for an advisory `freshness.sh` reported, emit
  NEEDS-DECISION with the advisory ID, whether the vulnerable path is
  reachable, and the eligibility date.

Apply the floor before the gate re-run, so the gate tests the set you keep.

Green: keep. Report each moved dep as `old -> new`. Leave the files
uncommitted. Majors still held back are one informational line, not findings.

Red: restore that package, report the failing output as HIGH.
