# Node: impl-review

Fresh-context review of the post-apply diff. Is it built right?

Owns: what changed, hostile probes (auth, empty/nil, races, compat, injection),
test coverage (do not run tests; the tests node already did), observability,
and doc accuracy for any changed prose.

Always launch at least one reviewer, even on a docs-only or one-line diff.
Launch one reviewer per routing block from `chad-review-route.sh`, scoped to
that block's hunks, all in ONE message. With no routing block (plain prose,
config), launch one reviewer over the whole diff. If routing failed, launch one
reviewer over the whole diff.

Every reviewer is `subagent_type: general-purpose`, `model: opus`,
`effort: high`. This skill explicitly sets that effort. Ignore the
`[REVIEW tier, sonnet]` hint routing prints: that is `/chad-review`'s tiering,
not ultra-audit's. When `RISK` is not `none`, name the risk surfaces in the
prompt so the reviewer probes them first.

Prompt contract: `resources/fanout.md`. Rubric path: `pass-reference.md`
sections BEHAVIOR AND RISK, TESTS (coverage), OBSERVABILITY. Do not paste the
rubric. Output contract from `fanout.md`, verbatim: report everything, no
filtering. No edit, no commit, no deploy.
