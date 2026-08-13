# Node: impl-review

Fresh-context review of the post-apply diff. Is it built right?

Owns: what changed, hostile probes (auth, empty/nil, races, compat, injection),
test coverage (do not run tests; the tests node already did), observability.

When `AGENTS=0`, do this inline in the parent. When `AGENTS` is 1 or more,
launch one reviewer per language block from `chad-review-route.sh`, scoped to
that block's hunks. Prompt contract: `resources/fanout.md`. Rubric path:
`pass-reference.md` sections BEHAVIOR AND RISK, TESTS (coverage), OBSERVABILITY.
Do not paste the rubric.

Output contract from `fanout.md`, verbatim. No edit, no commit, no deploy.
