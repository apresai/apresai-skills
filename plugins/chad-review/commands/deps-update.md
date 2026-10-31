---
name: deps-update
description: Bring a repo's dependencies to the newest release within each current major, as their own PR. Use when the user invokes /deps-update, asks to update, bump, or refresh dependencies, wants the latest deps, or when a review's freshness audit reports an outdated or vulnerable direct dependency. Takes security fixes immediately, never crosses a major without being asked, keeps each ecosystem's update only if the project's gate re-runs green, and ends in a deps PR reviewed by /ultra-audit.
---

# Deps Update

Dependency updates are their own change, not a side effect of reviewing a
feature. `/ultra-audit` only audits dependencies; this command changes them.
One run, one `deps:` PR, so feature diffs never carry lockfile churn and every
bump is reviewed and revertable on its own.

`resources/...` paths resolve against
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/...`.

## Steps

1. **Start clean, from fresh main.** `git status --porcelain` must be empty
   (stop and say so otherwise). Cut the branch the shipping rules require:
   `git fetch origin && git checkout -b deps-<yyyy-mm-dd> origin/main`, or the
   worktree equivalent.
2. **Gate first.** Run the project's gate exactly as `resources/nodes/gate.md`
   discovers it. Red before any update: stop and report it; updates on a red
   tree cannot be attributed.
3. **Audit.** `bash resources/freshness.sh`. Note every direct dependency with
   a CVE, an end-of-life runtime, or a newer in-range release.
4. **Update in range.** Follow `resources/nodes/apply-deps.md`: the ecosystem's
   own in-range updater (`go get -u ./... && go mod tidy`, `npm update`, or
   the native equivalent), snapshot first, gate re-run, keep or revert per
   manifest. Take the newest in-range release, never alpha, beta, rc, or a
   preview, and never a new major unless the user asked for that major.
5. **Security beyond range.** A CVE whose only fix is a new major is a
   NEEDS-DECISION block with the advisory, the fixed version, and the breaking
   surface. Do not take the major unasked.
6. **Report and verify.** List every version that moved (`old -> new`) from
   the lockfile or `go.sum` diff, and run `npm audit signatures` when npm
   packages moved. Re-run `freshness.sh`: no direct dependency the update
   could reach may still show a fixable CVE.
7. **Ship it as a PR.** Commit only the manifests and lockfiles, as
   `deps: in-range updates <date>`, with the moved list in the body. Open the
   PR, run `/ultra-audit` on it, fix what it finds, and merge per the shipping
   rules. Nothing moved: say so and open nothing.

## Rules

- Never cross a major unasked. Never pin to a dist-tag like `latest`.
- Never revert with `git checkout` (it would drop the user's edits): restore
  from the snapshot, as `apply-deps.md` says.
- Never deploy, publish, or release from this command.
