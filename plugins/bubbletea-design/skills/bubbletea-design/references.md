# References: upstream docs, examples, ecosystem

Quick lookup index. Everything here is upstream. When in doubt, the source of truth is the GitHub repo, not this skill.

## Core libraries (canonical paths)

| Library | Import path | Version | Repo |
|---|---|---|---|
| Bubble Tea v2 | `charm.land/bubbletea/v2` | v2.0.6+ | https://github.com/charmbracelet/bubbletea |
| Bubbles v2 | `charm.land/bubbles/v2` | v2.1.0+ | https://github.com/charmbracelet/bubbles |
| Lip Gloss v2 | `charm.land/lipgloss/v2` | v2.0.3+ | https://github.com/charmbracelet/lipgloss |
| huh (forms) | `charm.land/huh/v2` | v2.0.3+ | https://github.com/charmbracelet/huh |
| Harmonica (physics) | `github.com/charmbracelet/harmonica` | latest | https://github.com/charmbracelet/harmonica |

## Official documentation

- Bubble Tea v2 upgrade guide: https://github.com/charmbracelet/bubbletea/blob/main/UPGRADE_GUIDE_V2.md
- Bubbles v2 upgrade guide: https://github.com/charmbracelet/bubbles/blob/main/UPGRADE_GUIDE_V2.md
- Lip Gloss v2 upgrade guide: https://github.com/charmbracelet/lipgloss/blob/main/UPGRADE_GUIDE_V2.md
- Bubble Tea v2 announcement: https://github.com/charmbracelet/bubbletea/discussions/1374
- Bubble Tea tutorials: https://github.com/charmbracelet/bubbletea/tree/main/tutorials
- Bubble Tea examples (50+): https://github.com/charmbracelet/bubbletea/tree/main/examples
- huh README: https://github.com/charmbracelet/huh

## API docs (pkg.go.dev)

- https://pkg.go.dev/charm.land/bubbletea/v2
- https://pkg.go.dev/charm.land/bubbles/v2
- https://pkg.go.dev/charm.land/lipgloss/v2
- https://pkg.go.dev/charm.land/huh/v2

## Community / addons

| What | Where |
|---|---|
| BubbleZone (mouse zones / clickable regions) | https://github.com/lrstanley/bubblezone |
| bubbletea-overlay (modal windows) | https://github.com/rmhubbert/bubbletea-overlay |
| Additional bubbles (community components) | https://github.com/charm-and-friends/additional-bubbles |
| bubble-table (enhanced table) | https://github.com/evertras/bubble-table |
| catwalk (test framework alternative) | https://github.com/knz/catwalk |
| teatest (official testing helpers) | https://github.com/charmbracelet/x/tree/main/exp/teatest |
| teatest pkg.go.dev reference | https://pkg.go.dev/github.com/charmbracelet/x/exp/teatest |

## Worked examples worth studying

| Project | Why look at it |
|---|---|
| `bubbletea/examples/*` | Reference patterns for every bubble |
| `bubbletea-app-template` | A scaffold for a real app (CI, GoReleaser, golangci-lint) |
| `grok-chat` (this codebase) | Chat REPL + slash palette + model picker + concurrent streaming + Braille banner + filled input |
| `gimage` (`~/dev/gimage/internal/tui/`) | Multi-step wizard (8 steps), NavigateMsg screen routing, Tab-cycled multi-component focus, lipgloss.Place centering; v1 but the patterns translate 1:1 to v2 |
| `emailz` (`~/dev/emailz/internal/cli/tui.go`) | Minimal list+textinput config manager: canonical example of bubbles/list + textinput with view-enum routing; v1, migrate to v2 for production use |
| `glow` (charmbracelet/glow) | Markdown viewer; shows great use of viewport + lipgloss styles |
| `gum` (charmbracelet/gum) | CLI prompt primitives; pairs huh patterns with shell-friendly composability |
| `wishlist` (charmbracelet/wishlist) | SSH directory; multi-pane layout, mouse focus, BubbleZone |

## Keyboard protocols

- Kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- modifyOtherKeys (xterm): https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-The-Alternate-Escape-Convention

Supported terminals (Kitty protocol): Ghostty, Kitty, WezTerm, foot, Alacritty (recent), iTerm2 (with keyboard protocol enabled), Rio, Contour.

## Image / ASCII art tooling

- `chafa`: image → terminal text. `brew install chafa`. See `patterns.md` recipe for Braille banner.
- `figlet`: ASCII text from a string. `brew install figlet`.
- `lolcat`: gradient color wrapper for any text. `brew install lolcat`.

## Color references

- 256-color palette chart: https://www.ditig.com/256-colors-cheat-sheet
- Lip Gloss color examples: https://github.com/charmbracelet/lipgloss/blob/main/examples/colors/main.go

## Reading order recommendation

For a new TUI developer landing in this skill:

1. Skim **SKILL.md** for the big picture and the minimum-viable program.
2. Read **architecture.md** to internalize Model / Update / View / Cmd.
3. Read **components.md** to know what's already built.
4. Skim **styling.md**. Refer back when laying out a specific thing.
5. Read **patterns.md**. Pick the recipe closest to what you're building.
6. Read **gotchas.md** before your first commit.
7. Refer to **design.md** when reviewing what you've built.
8. Use **references.md** for upstream verification.

For an experienced Bubble Tea v1 dev migrating to v2: just **gotchas.md** is enough.

For someone asking "how do I make my existing TUI look better": **design.md** + **styling.md**.

## Versioning notes

The v2 stack went GA in early 2026. Version pinning recommendation for new projects (as of 2026-05-21):

```
charm.land/bubbletea/v2  v2.0.6
charm.land/bubbles/v2    v2.1.0
charm.land/lipgloss/v2   v2.0.3
charm.land/huh/v2        v2.0.3  // if you're using forms
```

These are stable. Future minor versions should not break the patterns documented here.
