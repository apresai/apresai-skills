# Node: challenger

Fresh context. Opposite goal: break confidence in the change itself, and find
what impl-review missed.

`subagent_type: general-purpose`, `model: opus`, `effort: high`. This skill
explicitly sets that effort.

Input: the post-apply diff plus every finding raised so far (so it does not
repeat them). Not the parent's hoped-for verdict. Not this conversation.

Ask whether the change is worth doing: wrong design, a tradeoff that will not
hold, an assumption that is false, a requirement the diff misread. Each of
those must say what can go wrong, why this path is vulnerable, the likely
impact, and a concrete change that reduces the risk. Then raise any missed
defect.

Report every finding as `SEVERITY | <confidence 0-100> | file:line | finding`,
low-severity ones included. Do not filter: the verify node rules on every
finding, and confidence is a label for ordering, never a cutoff. Ruling on
impl-review's findings is the verify node's job, not this one's. End with
HOLDS or DOES NOT HOLD for the change itself.
