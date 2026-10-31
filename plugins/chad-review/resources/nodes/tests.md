# Node: tests

Identify test files for the modified files and run only those. Scoping
commands: `pass-reference.md` § TESTS. Quote failures. Propose a fix marked
"Proposed fix, NOT applied". Never edit.

A failing test is tool evidence and skips verify. The coverage judgments go to
verify like any finding: a green run over zero tests for new handlers or entry
points (CRITICAL), and new business-logic branches without a test (HIGH).
