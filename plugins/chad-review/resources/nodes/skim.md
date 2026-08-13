# Node: skim

Parent only. No agents. Leaf diffs.

- Secrets, credentials, tokens, or PII in the diff
- Commands, paths, or flags in docs that the repo does not have
- A config change that widens permissions, adds `pull_request_target` with
  untrusted PR code, or poisons a cache

One line per finding. Clean if none.
