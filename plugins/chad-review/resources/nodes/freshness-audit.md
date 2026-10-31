# Node: freshness-audit

Runs in the real worktree (lockfiles and installed packages are there):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/freshness.sh"
```

Audit only. Review never updates dependencies: `/deps-update` does that as its
own PR. Judgment of REF polarity, SCAN none, N/A, and COVERAGE GAP is in
`commands/chad-review.md` § 5 FRESHNESS; read that section when this node
runs. Prefer `FIX` records over raw `SCAN` lines.

`freshness.sh` reports what is installed, not what is newer. For each direct
dependency the diff added or changed, look for a newer stable release within
its current major (pins are exact, so the manifest range says nothing):
`npx -y npm-check-updates@23.1.1 --target minor --filter <name>` (read-only
without `-u`) for npm, pnpm, and yarn; `go list -m -u <module>` for Go. Other
ecosystems: say the check was not run.

Where the records go (`nodes/receipt.md`):

- A CVE or end-of-life runtime on a direct dependency this diff added or
  changed: counted. Fix it in this PR.
- A newer in-range release for a dependency the diff touched, with no CVE:
  Follow-up, for `/deps-update`.
- Anything on dependencies the diff did not touch, any COVERAGE GAP, and
  bundled or transitive advisories: Follow-up.

Recommend `/deps-update` in the report when any Follow-up item above is a
dependency update or a fixable CVE.
