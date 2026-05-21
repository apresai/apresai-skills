---
name: bubbletea-design
description: Build beautiful, idiomatic terminal UIs in Go with Bubble Tea v2, Bubbles v2, and Lip Gloss v2. Triggers when the user wants to create a Go TUI, asks about charmbracelet libraries, wants to migrate from v1 to v2, or wants to design a sexy terminal interface (chat REPL, dashboard, picker, form, wizard). Provides architecture patterns, component catalog, styling recipes, async/streaming patterns, and a v1→v2 migration map.
---

# Bubble Tea v2 — TUI Design Knowledge Base

This skill is the reference for building production-grade, visually polished terminal UIs on top of the **charm.land** v2 stack. It is opinionated toward what actually works in 2026: declarative Views, Kitty keyboard protocol, mouse-friendly layouts, adaptive light/dark theming, and async patterns that don't deadlock under streaming workloads.

## When to use this skill

Use this skill when the user:

- Wants to **build a new TUI in Go** (chat, dashboard, form, wizard, picker, log viewer, file browser, REPL).
- Asks about **`bubbletea`, `bubbles`, `lipgloss`, or `huh`** — including v1 *and* v2 (this skill defaults to v2 and provides a v1→v2 migration map).
- Wants to **migrate an existing v1 app to v2** (different import paths, declarative View, KeyPressMsg interface, mouse message split).
- Wants to make an existing TUI look **more polished / sexy / on-brand** (borders, gradients, ASCII banners, status footers, mouse wheel scroll).
- Asks about a specific component (textarea, viewport, list, table, spinner, progress, form, etc.).
- Hits a known gotcha (e.g., "shift+enter doesn't work", "ctrl+c doesn't quit", "my background doesn't fill empty rows", "my placeholder is messy").

If the user asks something narrow ("how do I render a table"), jump straight to `components.md`. For architectural questions ("how do I structure my Update loop with multiple concurrent requests"), start with `architecture.md` and `patterns.md`.

## Reading order (Claude — pick what you need)

The skill ships as one entry + seven topic files. Don't read them all up front; load only what the task requires.

| File | When to load |
|---|---|
| `architecture.md` | Model/Update/View contract, msg routing, async + streaming via `prog.Send` |
| `styling.md` | Lip Gloss colors, borders, padding, layout primitives (JoinVertical, Place), adaptive light/dark |
| `components.md` | Quick reference for every bubble: textarea, viewport, list, table, spinner, progress, help, paginator, filepicker, stopwatch, timer, key, cursor |
| `patterns.md` | Recipes — chat REPL, slash-command palette, model picker, dashboard panes, modal overlay, form wizard, streaming with inflight counter |
| `gotchas.md` | v1→v2 migration map + the bugs that bit real projects (don't repeat them) |
| `design.md` | Visual design principles — color palettes, spacing, alignment, what makes a TUI "feel" amazing instead of utilitarian |
| `references.md` | Canonical links to upstream docs, repos, addons, color charts, terminal protocols |

## Quick-reference: minimum-viable program (v2)

This is the smallest correct v2 program. Memorize the shape — every TUI starts from here.

```go
package main

import (
    "fmt"
    "os"

    tea "charm.land/bubbletea/v2"
    "charm.land/lipgloss/v2"
)

type model struct{ count int }

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.KeyPressMsg:
        switch msg.String() {
        case "q", "ctrl+c":
            return m, tea.Quit
        case "space", "enter":
            m.count++
        }
    }
    return m, nil
}

func (m model) View() tea.View {
    s := lipgloss.NewStyle().
        Bold(true).
        Foreground(lipgloss.Color("39")).
        Border(lipgloss.RoundedBorder()).
        Padding(1, 2).
        Render(fmt.Sprintf("Count: %d\n\nSpace/Enter to increment, q to quit.", m.count))

    v := tea.NewView(s)
    v.AltScreen = true
    v.MouseMode = tea.MouseModeCellMotion
    return v
}

func main() {
    p := tea.NewProgram(model{})
    if _, err := p.Run(); err != nil {
        fmt.Fprintln(os.Stderr, err)
        os.Exit(1)
    }
}
```

Differences from v1 that bite when you're not paying attention:

- `import tea "charm.land/bubbletea/v2"` (NOT `github.com/charmbracelet/...`)
- `Update` switch on `tea.KeyPressMsg`, not `tea.KeyMsg` (the latter is an interface in v2)
- `View()` returns `tea.View`, not `string`. AltScreen / MouseMode / WindowTitle / Cursor live on the View struct.
- Mouse handling splits into `MouseClickMsg`, `MouseReleaseMsg`, `MouseWheelMsg`, `MouseMotionMsg` — no more `msg.Action`.
- `p.Run()`, not `p.Start()`.

If you find yourself writing `tea.WithAltScreen()` as a NewProgram option, stop — that API is gone in v2.

## Module versions (verified working as of 2026-05-21)

```go.mod
require (
    charm.land/bubbletea/v2 v2.0.6
    charm.land/bubbles/v2   v2.1.0
    charm.land/lipgloss/v2  v2.0.3
    charm.land/huh/v2       v2.0.0  // optional, for forms
)
```

`go mod tidy` will resolve the indirects (ultraviolet, x/ansi, x/term, colorprofile, displaywidth, harmonica, etc.).

## Design philosophy in one paragraph

A great TUI uses the constraints of the terminal as a feature. You have a 256-color palette, ~80x24 to ~200x60 cells, no animations to speak of (apart from spinners and tickers), and a keyboard that's instantaneous. Lean into that: **make every cell mean something**, **don't waste rows**, **align everything to a vertical or horizontal axis**, and **respect the user's terminal theme** by using adaptive colors. Borders aren't decoration — they group concepts. Whitespace isn't waste — it gives the eye somewhere to rest. The accent color (one!) flags what's important. See `design.md` for the long version.

## Working in this skill

When asked to build a new TUI:

1. Skim `architecture.md` to lock in the Model/Update/View pattern with the user's specific msg types.
2. Pick components from `components.md`. Default to existing bubbles (`textarea`, `viewport`, `list`, `table`, `spinner`) before rolling your own.
3. Layout with patterns from `patterns.md`. The recipes there map directly onto common shapes — don't reinvent.
4. Style with `styling.md`. Set a single accent color, use adaptive light/dark, use `lipgloss.Place` for centered empty states.
5. Cross-check `gotchas.md` before shipping — half the bugs in v2 are listed there.

When asked to fix or improve an existing TUI:

1. Identify the file structure. If it's v1, point at `gotchas.md` for the migration.
2. Locate the symptom (rendering issue → `styling.md`; key handling → `architecture.md` + `gotchas.md`; component-specific → `components.md`).
3. Apply the smallest correct change. TUI code is dense; avoid sweeping rewrites.

## Publishing this skill

To share via the apresai skills repo:

```bash
cd ~/dev/apresai-skills    # or wherever the repo lives
mkdir -p bubbletea-design
cp -r ~/.claude/skills/bubbletea-design/* bubbletea-design/
git add bubbletea-design
git commit -m "feat: bubble tea v2 design knowledge base"
git push
```

Users install by symlinking or cloning into `~/.claude/skills/`. Once installed, this skill auto-triggers on TUI-related requests via the description above.
