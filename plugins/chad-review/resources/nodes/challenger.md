# Node: challenger

Fresh context. Opposite goal: break confidence in the change and in the
findings already raised.

Input: the post-apply diff plus every finding from impl-review and spec-vs-diff.
Not the parent's hoped-for verdict. Not this conversation.

Per finding: accept, reject, needs-more-evidence, or a missed finding.
For every surviving HIGH or CRITICAL, reproduction is required: a file:line
you actually read, or a command you actually ran. A second opinion on the
same paragraph is not enough.

Also ask whether the change is worth doing: wrong design, a tradeoff that will
not hold, an assumption that is false. Each of those must say what can go
wrong, why this path is vulnerable, the likely impact, and a concrete change
that reduces the risk.

Report every finding as `SEVERITY | <confidence 0-100> | file:line | finding`,
low-severity ones included. Do not filter for importance: the score node
filters once, with everything in view. End with HOLDS or DOES NOT HOLD for
the change itself; with nothing to report, say HOLDS and return none.
