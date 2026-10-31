# Node: sweep

Deep depth only. One fresh gap-finder after verify, looking only for what
everyone missed. Run it once: in published measurements a second round
roughly doubled false positives, and every false positive now costs a change.

- `subagent_type: general-purpose`, `model: opus`, `effort: high`.
- Input: the post-apply diff, every CONFIRMED and PLAUSIBLE finding (do not
  repeat them), every REFUTED finding with its evidence (do not re-raise one
  without new evidence that defeats that refutation), and the rubric path.
- Angles: moved or extracted code that dropped a guard; a shrunken lock or
  transaction scope; setup/teardown asymmetry in tests; a flipped default; an
  error now swallowed; a caller of a changed function or contract the diff did
  not update (grep the repo for the old names); a doc, comment, or memory note
  the change made false.
- Output contract from `fanout.md`, verbatim. "Clean" when nothing new. Do
  not pad.

Its findings go through `verify` (one more batch), then into the verdict. No
second sweep.
