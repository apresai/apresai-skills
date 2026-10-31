# Node: freshness-audit

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/freshness.sh"
```

Audit only. Review never updates dependencies: `/deps-update` does that as its
own PR. Judgment of REF polarity, SCAN none, N/A, and COVERAGE GAP is in
`commands/chad-review.md` § 5 FRESHNESS; read that section when this node
runs. Prefer `FIX` records over raw `SCAN` lines.

Where the records go (`nodes/receipt.md`):

- A CVE or end-of-life runtime on a direct dependency this diff added or
  changed: counted. Fix it in this PR.
- Anything on dependencies the diff did not touch, any COVERAGE GAP, and
  bundled or transitive advisories: Follow-up. Recommend `/deps-update` in the
  report when any in-range update or fixable CVE exists.
