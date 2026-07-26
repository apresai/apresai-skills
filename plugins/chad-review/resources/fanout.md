# chad-review: writing sub-agent prompts

Read this ONLY when you are about to launch an agent: `standard` shape, or
`light`/`deps` where `freshness.sh` emitted `DEP` records needing version
resolution. On a `light` review that spawns nothing, none of this applies, which
is why it lives here rather than in the always-loaded skill body.

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
- Report every issue you find, including low-severity ones. Do NOT filter for
  importance: that is a later pass's job, once, with everything in view.
  Coverage is your job, ranking is not.
- Score confidence honestly, on this scale, and do not inflate it. A separate
  agent re-scores every finding independently, and anything under 80 is dropped
  rather than deferred, so a padded score costs you the finding:
  - 0: false positive under light scrutiny, or a pre-existing issue.
  - 25: might be real, could not verify it. Stylistic and not called out in
    the project's own guidelines.
  - 50: verified real, but a nitpick or rare in practice, and unimportant next
    to the rest of the diff.
  - 75: double-checked, very likely hit in practice, the existing approach is
    insufficient, or the project's guidelines name it directly.
  - 100: confirmed, will happen frequently, evidence directly supports it.
- Emit one "## <PASS NAME>" heading per pass you own, findings underneath,
  in the order the passes are numbered.
- A pass with no findings outputs exactly: Clean
- A sub-check whose project convention is absent outputs exactly:
  TAG | N/A - convention not detected
(FRESHNESS agent: emit the recommendation table first, that is data, then the
 severity and UPGRADE-NOW lines as TAG | dep | <=15-word recommendation.)
```

Prompt skeleton:

```
You are reviewing a pre-commit diff on the <project> repo. You own passes
1 DRIFT, 2 BEHAVIOR (what changed), 3 TESTS (coverage only, do not run tests),
4 OBSERVABILITY, and 6 SIMPLIFY.

The diff under review (from `git diff HEAD` + untracked files):
<paste diff>

Project context (detected during pre-flight):
- OpenAPI spec: <path or "not present">
- Type-generation command / spec lint command: <or "not present">
- Route-parity test: <command or "not present">
- Data-model doc: <path or "not present">

Pass rubrics. Read these BEFORE you start; they are required, not background:
  file: <RESOLVED absolute path, see below>
  sections: <only the § headings for the passes this agent owns>
Within each section read only the language subsections matching this diff
(<languages detected>). Do not read the whole file.

<paste the output contract>. Do not edit files, do not commit, and do not run any
command that deploys, publishes, releases, or migrates. Running the project's
build, tests, linters, and generators IS expected and they do write to disk.
```

Agent call. `model` is REQUIRED, from §"Model tiering":

```json
{
  "description": "Reviewer: DRIFT, BEHAVIOR, TESTS coverage, OBSERVABILITY, SIMPLIFY",
  "subagent_type": "feature-dev:code-reviewer",
  "model": "<REVIEW tier for this session, normally sonnet>",
  "prompt": "<self-contained prompt as above>"
}
```
