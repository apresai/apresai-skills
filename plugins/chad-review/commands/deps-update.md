---
name: deps-update
description: Bring a repo's dependencies to the newest release within each current major, as their own PR. Use when the user invokes /deps-update, asks to update, bump, or refresh dependencies, wants the latest deps, or when a review's freshness audit reports an outdated or vulnerable direct dependency. Takes security fixes immediately, never crosses a major without being asked, moves exact pins (npm-check-updates for npm, pnpm, and yarn, go get -u for Go), keeps each ecosystem's update only if the project's gate re-runs green and the blocked-packages and osv checks pass, and ends in a deps PR reviewed by /ultra-audit.
---

# Deps Update

Dependency updates are their own change, not a side effect of reviewing a
feature. `/ultra-audit` only audits dependencies; this command changes them.
One run, one `deps:` PR, so feature diffs never carry lockfile churn and every
bump is reviewed and revertable on its own.

Every resource path below is spelled in full. Run the bash lines as written
from the project root.

## Steps

1. **Start clean, from fresh main.** `git status --porcelain` must be empty
   (stop and say so otherwise). Cut the branch the shipping rules require:
   `git fetch origin && git checkout -b deps-<yyyy-mm-dd> origin/main`, or the
   worktree equivalent.
2. **Gate first.** Run the project's gate exactly as
   `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/nodes/gate.md`
   discovers it, and the blocked-packages check as `apply-deps.md` discovers
   it (`check-blocked-deps`). Red, or a blocked-package hit, before any
   update: stop and report it; updates on a red tree cannot be attributed,
   and a hit already on main is not the update's doing.
3. **Audit.**
   `bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/freshness.sh"`.
   Note every direct dependency with a CVE, an end-of-life runtime, or a newer
   in-range release.
4. **Update in range.** Follow
   `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/nodes/apply-deps.md`
   exactly: snapshot first, then per ecosystem root:
   - npm, pnpm, or yarn: `npx -y npm-check-updates@23.1.1 --target minor -u`
     (add `--workspaces --root` in a monorepo), then the repo's own install
     (`pnpm install` with `pnpm-lock.yaml`, `yarn install` with `yarn.lock`,
     else `npm install`). `npm update` is not used: it never moves an exact
     pin, and exact pins are the house rule.
   - Go: `go get -u ./... && go mod tidy` (stays in the major).
   - Other ecosystems: the native in-range updater, or skip and say so.

   Then the gate re-run, the blocked-packages check (`check-blocked-deps`),
   and osv via `freshness.sh`, with keep or revert per ecosystem root. Take
   the newest in-range release, never alpha, beta, rc, or a preview, and
   never a new major unless the user asked for that major.
5. **Security beyond range.** A CVE whose only fix is a new major is a
   NEEDS-DECISION item with the advisory, the fixed version, and the breaking
   surface. Do not take the major unasked.
6. **Report and verify.** List every version that moved (`old -> new`) from
   the lockfile or `go.sum` diff. Run `npm audit signatures` when
   `package-lock.json` moved; in a pnpm or yarn repo say it was skipped (it
   reads npm's lockfile). Confirm the blocked-packages check and the
   `freshness.sh` re-run from step 4 were clean on everything kept: no direct
   dependency the update could reach may still show a fixable CVE, and no
   blocked package may remain. List every NEEDS-DECISION item: each root
   apply-deps reverted (red gate or blocked-package hit) and each step 5
   major.
7. **Ship it as a PR.** Stage by name only the manifests and lockfiles that
   moved (every workspace `package.json` included), and commit as
   `deps: in-range updates <date>`. The PR body carries the moved list and
   the NEEDS-DECISION list. Open the PR, run `/ultra-audit` on it, fix what it
   finds, and merge per the shipping rules. Nothing moved: say so, give the
   NEEDS-DECISION list if there is one, and open nothing.

## Rules

- Never cross a major unasked. Never pin to a dist-tag like `latest`; the
  updater itself runs at an exact version (`npm-check-updates@23.1.1`).
- Never revert with `git checkout` (it would drop the user's edits): restore
  from the snapshot and reinstall, as `apply-deps.md` says.
- Never deploy, publish, or release from this command.
