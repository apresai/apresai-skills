# Node: sweep

One fresh gap-finder after verify, looking only for what everyone missed.
Run it once. A second round roughly doubled false positives in published
measurements, and with fix-everything every false positive costs a change.

- `subagent_type: general-purpose`, `model: opus`, `effort: high`.
- Input: the post-apply diff, the list of CONFIRMED and PLAUSIBLE findings
  (so it does not repeat them), and the rubric path from `fanout.md`.
- Angles: moved or extracted code that dropped a guard; a shrunken lock or
  transaction scope; setup/teardown asymmetry in tests; a flipped default in
  config; an error now swallowed; a caller of a changed function the diff did
  not update; a doc or comment the change made false.
- Output contract from `fanout.md`, verbatim. "Clean" when nothing new. Do
  not pad.

Every new finding goes through `verify` (one more verifier batch), then into
the verdict. No further sweep after that.
