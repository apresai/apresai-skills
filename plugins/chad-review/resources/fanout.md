# chad-review: writing sub-agent prompts

Read this ONLY when you are about to launch an agent: every `/ultra-audit`
run, and any `/chad-review` run that fans out or launches a verifier. It lives
here rather than in the always-loaded bodies so the contract is written once.

Model tiering, the agent budget, and the Phase 1 / Phase 2 split stay in
`commands/chad-review.md` §"Execution strategy"; this file is only the prompt
contract.

---

## Writing sub-agent prompts

Self-contained, always:

- One sentence of goal, naming the passes the agent owns.
- The diff. Sub-agents cannot see your conversation.
- The rubric's PATH and section names, never its text. Sub-agents cannot see
  your conversation, but they can read files. Pasting the sections instead would
  charge the same rubric three times: the parent's context to read it, the
  parent's output tokens to copy it, and the agent's input to receive it, all to
  hand over a file the agent can open itself. Naming the sections is mandatory,
  and so is the agent actually reading them, which is why the skeleton phrases it
  as a requirement rather than a suggestion.

  **Resolve the path before you paste it.** A sub-agent prompt is a string, not
  a shell: a literal `${CLAUDE_PLUGIN_ROOT:-...}` arrives unexpanded and the
  agent's Read fails on a path containing `${`. That fails silently, since the
  agent then reviews without the rubric it was told was mandatory. Expand it in
  the parent first, for example with
  `echo "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/chad-review}/resources/pass-reference.md"`,
  and paste the absolute path the shell prints.
- The project's spec files, validation commands, test harness, and doc locations
  as detected in pre-flight. Absent ones stated as absent, so the agent reports
  that sub-check N/A.
- The output contract verbatim, plus the no-edit and checks-not-actions rules.

**Output contract (paste verbatim into every sub-agent prompt):**

```
Output. Strict, no exceptions:
- Zero preamble, zero restated diff, zero methodology narration.
- One line per finding:
  SEVERITY | <confidence 0-100> | file:line | <=15-word finding
- Report every issue you find, including ones you are uncertain about or
  consider low-severity. Do not filter for importance or confidence: a
  separate verification step rules on every finding, and it drops one only
  when it can quote code or command output that disproves it. A finding you
  hold back is a bug nobody fixes. Pass through every candidate that has a
  nameable failure scenario. Omit only pure style or naming preferences that
  no project rule names.
- The confidence number is a label for ordering, never a cutoff. Score it
  honestly:
  - 25: might be real, could not verify it.
  - 50: verified real, rare in practice or minor.
  - 75: double-checked, very likely hit in practice, or a project rule names it.
  - 100: confirmed, evidence directly supports it.
- You may suggest PRE-EXISTING when the failing line is untouched by the diff
  and the diff does not change whether it is reached. Still report it; the
  verifier decides, and an unconfirmed suggestion counts as the diff's.
- Emit one "## <PASS NAME>" heading per pass you own, findings underneath,
  in the order the passes are numbered.
- A pass with no findings outputs exactly: Clean
- A sub-check whose project convention is absent outputs exactly:
  TAG | N/A - convention not detected
```

Prompt skeleton:

```
You are reviewing a pre-commit diff on the <project> repo. You own passes
1 DRIFT, 2 BEHAVIOR (what changed), 3 TESTS (coverage only, do not run tests),
and 4 OBSERVABILITY.

The diff under review (`git diff HEAD` + untracked files; for /ultra-audit,
taken inside the pr-stage.sh worktree, which holds the whole branch):
<paste diff>

Project context (detected during pre-flight):
- OpenAPI spec: <path or "not present">
- Type-generation command / spec lint command: <or "not present">
- Route-parity test: <command or "not present">
- Data-model doc: <path or "not present">
- docs-drift records: <paste the CONTRA/STALE/MARKER/INDEXED rows, or "none">
  (for the reviewer that owns a status-bearing doc: the status-bearing block's
  reviewer, or the single reviewer of a fast-depth run; read each flagged doc
  IN FULL, not just its hunks)

Pass rubrics. Read these BEFORE you start; they are required, not background:
  file: <RESOLVED absolute path, see below>
  sections: <only the § headings for the passes this agent owns>
Within each section read only the language subsections matching this diff
(<languages detected>). Do not read the whole file.

<paste the output contract>. Do not edit files, do not commit, and do not run any
command that deploys, publishes, releases, or migrates. Running the project's
build, tests, linters, and generators IS expected and they do write to disk.
```

Agent call. `model` is REQUIRED and so is the effort the node file names.
The skill asks for both explicitly, which is what permits setting them.
`/ultra-audit`: `opus` everywhere; finders `medium` at fast depth and `high`
at deep depth; verifiers, challenger, sweep, and spec-vs-diff always `high`.
`/chad-review`: its §"Model tiering" for reviewers (session-relative tier,
effort inherited); verifiers `opus`, `high`:

```json
{
  "description": "Reviewer: DRIFT, BEHAVIOR, TESTS coverage, OBSERVABILITY",
  "subagent_type": "general-purpose",
  "model": "<opus, or chad-review's REVIEW tier for a chad-review reviewer>",
  "effort": "<what the node file names; omit only for a chad-review reviewer>",
  "prompt": "<self-contained prompt as above>"
}
```
