# Node: challenger

Deep depth only. Fresh context. Opposite goal: break confidence in the change
itself, and find what impl-review missed.

`subagent_type: general-purpose`, `model: opus`, `effort: high`. This skill
explicitly sets that effort.

Input: the post-apply diff plus every finding raised so far (do not repeat
them). Not the parent's hoped-for verdict. Not this conversation.

Ask whether the change is worth doing: wrong design, a tradeoff that will not
hold, an assumption that is false, a requirement the diff misread. Each
concern is a finding with a `file:line`, and must say what goes wrong, why
this path is vulnerable, the likely impact, and a concrete change that
reduces the risk. Then raise any missed defect.

Report every finding as `SEVERITY | <confidence 0-100> | file:line | finding`,
low-severity ones included. Do not filter. End with HOLDS or DOES NOT HOLD.

That verdict is printed but does not gate on its own: a stochastic opinion
with no fix path cannot block a merge. Its concerns gate through verify like
any finding, and a verified design concern counts until fixed or until the
user decides it (NEEDS-DECISION).
