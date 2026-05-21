# Bubble Tea Design Skill for Claude

A production-grade knowledge base for building beautiful terminal UIs in Go using the **charm.land** v2 stack: Bubble Tea, Bubbles, Lip Gloss, and (optionally) huh.

When installed, this skill auto-triggers whenever a user asks Claude to:

- Build a new Go TUI (chat, dashboard, form, wizard, picker, log viewer, REPL)
- Migrate an existing v1 Bubble Tea app to v2
- Make an existing TUI look more polished or "sexy"
- Get help with a specific component (`textarea`, `viewport`, `list`, `table`, etc.)
- Debug a known gotcha (Shift+Enter not working, empty rows not filling background, etc.)

## What's included

Seven topic files plus an entry point, ~3,000 lines total:

| File | What it covers |
|---|---|
| `SKILL.md` | Entry point, frontmatter, when to trigger, minimum-viable program |
| `architecture.md` | Model/Update/View contract, msg routing, async + streaming via `prog.Send`, concurrent submits with turnID matching |
| `styling.md` | Lip Gloss colors, borders, padding, layout primitives (Join, Place), adaptive light/dark, recipes |
| `components.md` | Every bubble: textarea, viewport, list, table, textinput, spinner, progress, help, paginator, filepicker, key, cursor, stopwatch, timer |
| `patterns.md` | 10 copy-paste recipes — chat REPL, slash-command palette, model picker, dashboard panes, modal overlay, live streaming via custom writer, empty-state banner, huh form, etc. |
| `gotchas.md` | 28 v1→v2 migration items + the bugs that bit real projects |
| `design.md` | Visual design principles — color palettes, alignment, whitespace, empty states, what makes a TUI feel amazing |
| `references.md` | Canonical upstream docs, addons, color charts, terminal protocol references |

## Why this exists

The official Charmbracelet docs are excellent for individual components but don't connect them into production patterns. This skill fills the gap with:

- **Real recipes**, not toy examples — every pattern is sourced from a shipping production TUI (`grok-chat`, an OAuth-based Grok chat CLI).
- **Concrete migration map** — 28 v1→v2 changes, each with the symptom, cause, and fix in code.
- **Opinionated design guidance** — "one accent color", "borders group concepts", "the empty state is the first impression". Most TUI tutorials skip this.

## Installation

This skill ships as part of the [apresai-skills](https://github.com/apresai/apresai-skills) Claude Code marketplace. Install via:

```
/plugin install bubbletea-design@apresai-skills
```

Or symlink for local development:

```bash
git clone https://github.com/apresai/apresai-skills ~/dev/apresai-skills
ln -s ~/dev/apresai-skills/plugins/bubbletea-design/skills/bubbletea-design \
      ~/.claude/skills/bubbletea-design
```

Once installed, the skill auto-triggers based on the description — no manual invocation required.

## Versions covered

```
charm.land/bubbletea/v2  v2.0.6+
charm.land/bubbles/v2    v2.1.0+
charm.land/lipgloss/v2   v2.0.3+
charm.land/huh/v2        v2.0.0+  (optional, for forms)
```

Stable as of 2026-05-21. Future minor versions should not break the patterns documented here.

## Contributing

Bug reports and PRs welcome at https://github.com/apresai/apresai-skills.

When you ship a TUI built using this skill, capture the patterns that worked. The skill grows by accretion of real-world examples — file an issue with a screenshot and the code that produced it.
