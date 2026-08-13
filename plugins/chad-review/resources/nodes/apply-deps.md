# Node: apply-deps (freshness-update)

Only when this node is listed and the pre-flight gate was green. If the gate
was already red, print `FRESHNESS | update skipped: gate already red` and stop.

Run `freshness.sh` first if `freshness-audit` has not already run in this
invocation. Then, for each manifest it discovered:

- Go module: `go get -u ./... && go mod tidy`
- npm package: `npm update`
- Another ecosystem with a native in-range updater: use it. None: skip and say so

Snapshot every manifest and lockfile the update will touch (`cp` to a temp
dir) before changing them. Never `git checkout` to revert: that would also
revert the user's uncommitted manifest edits. Restore from the snapshot if
the gate re-run is red. Keep-or-revert is per manifest.

Green: keep. Report each moved dep as `old -> new`. Leave the files
uncommitted. Majors still held back are one informational line, not findings.

Red: restore that package, report the failing output as HIGH.
