# Gotchas — v1→v2 migration & common bugs

The list of things that bit real projects. Read top-to-bottom before your first v2 build; check the section that matches your symptom otherwise.

---

## 1. Import paths moved to `charm.land`

**Symptom**: `cannot find package`, or v1 examples don't compile with v2 features.

```go
// v1
import (
    tea "github.com/charmbracelet/bubbletea"
    "github.com/charmbracelet/bubbles/textarea"
    "github.com/charmbracelet/lipgloss"
)

// v2
import (
    tea "charm.land/bubbletea/v2"
    "charm.land/bubbles/v2/textarea"
    "charm.land/lipgloss/v2"
)
```

The `charm.land` domain redirects to the canonical module path. The official `github.com/charmbracelet/bubbletea/v2` import path is NOT directly importable — `go get` will fail with "module declares its path as: charm.land/bubbletea/v2 but was required as: github.com/charmbracelet/bubbletea/v2". **Always use `charm.land/...` in v2.**

---

## 2. `View()` returns `tea.View`, not `string`

**Symptom**: `cannot use ... (type string) as type tea.View`.

```go
// v1
func (m model) View() string {
    return "Hello"
}

// v2
func (m model) View() tea.View {
    return tea.NewView("Hello")
}
```

The View struct holds your rendered string in `Content` plus terminal-level flags (AltScreen, MouseMode, KeyboardEnhancements, Cursor, WindowTitle, BackgroundColor, etc.). All of those used to be `tea.WithAltScreen()` etc. as Program options — now they live on the View, and you set them every render.

---

## 3. Program options moved to View fields

| v1 NewProgram option / Cmd | v2 |
|---|---|
| `tea.WithAltScreen()` | `view.AltScreen = true` |
| `tea.WithMouseCellMotion()` | `view.MouseMode = tea.MouseModeCellMotion` |
| `tea.WithMouseAllMotion()` | `view.MouseMode = tea.MouseModeAllMotion` |
| `tea.WithReportFocus()` | `view.ReportFocus = true` |
| `tea.WithoutBracketedPaste()` | `view.DisableBracketedPasteMode = true` |
| `tea.WithInputTTY()` | Removed — v2 handles automatically |
| `tea.WithANSICompressor()` | Removed — new renderer optimizes automatically |
| `tea.EnterAltScreen` / `tea.ExitAltScreen` | Toggle `view.AltScreen` |
| `tea.HideCursor` / `tea.ShowCursor` | Set/unset `view.Cursor` |
| `tea.SetWindowTitle("X")` | `view.WindowTitle = "X"` |
| `tea.EnableMouse*` / `tea.DisableMouse` | Set `view.MouseMode` |

**Mental model**: stop thinking "I'll send a command to enable X". Start thinking "I'll declare what state I want; the runtime reconciles".

---

## 4. `tea.KeyMsg` is an interface

**Symptom**: `cannot type-switch on non-interface value`, or matching on `tea.KeyMsg` no longer fires.

`tea.KeyMsg` became an interface in v2. The concrete types are `tea.KeyPressMsg` and `tea.KeyReleaseMsg` (the latter only fires if `view.KeyboardEnhancements.ReportEventTypes = true`).

```go
// v1
case tea.KeyMsg:
    switch msg.String() { … }

// v2
case tea.KeyPressMsg:
    switch msg.String() { … }
```

If you want to match BOTH press and release, type-switch on `tea.KeyMsg` (the interface) and call `msg.String()`. But 99% of the time you want `KeyPressMsg`.

---

## 5. `tea.MouseMsg` is an interface; events split by type

**Symptom**: `msg.Action` doesn't exist; `msg.X`, `msg.Y` don't exist directly.

```go
// v1
case tea.MouseMsg:
    if msg.Action == tea.MouseActionPress && msg.Button == tea.MouseButtonLeft {
        x, y := msg.X, msg.Y
    }

// v2
case tea.MouseClickMsg:
    if msg.Button == tea.MouseLeft {
        mouse := msg.Mouse()
        x, y := mouse.X, mouse.Y
    }
case tea.MouseReleaseMsg:
case tea.MouseWheelMsg:
case tea.MouseMotionMsg:
```

To get the X/Y you now call `msg.Mouse()` — the message is an interface, the concrete Mouse value is behind that method.

Button constants also renamed:

| v1 | v2 |
|---|---|
| `tea.MouseButtonLeft` | `tea.MouseLeft` |
| `tea.MouseButtonRight` | `tea.MouseRight` |
| `tea.MouseButtonMiddle` | `tea.MouseMiddle` |
| `tea.MouseButtonWheelUp` | `tea.MouseWheelUp` |
| `tea.MouseButtonWheelDown` | `tea.MouseWheelDown` |

---

## 6. `p.Start()` → `p.Run()`

```go
// v1
p := tea.NewProgram(model{})
p.Start()  // or p.StartReturningModel()

// v2
p := tea.NewProgram(model{})
_, err := p.Run()
```

Run returns the final model and an error.

---

## 7. `textarea.DefaultKeyMap` is now a function

**Symptom**: `cannot use DefaultKeyMap (type func() KeyMap) as KeyMap`.

```go
// v1
km := textarea.DefaultKeyMap
km.InsertNewline = key.NewBinding(...)

// v2
km := textarea.DefaultKeyMap()
km.InsertNewline = key.NewBinding(...)
```

Same change for `textinput.DefaultKeyMap()` and `paginator.DefaultKeyMap()`. It's now a function so callers can't accidentally mutate the shared global.

---

## 8. Bubble component Styles field → method round-trip

**Symptom**: `cannot select on .Focused (type func() Styles ...)`.

In v1, components like textarea had `m.Styles` as a struct field — directly mutable:

```go
// v1
m.Styles.Focused.Base = lipgloss.NewStyle()....
```

In v2, `Styles` is a method. Get → mutate → set:

```go
// v2
s := m.Styles()
s.Focused.Base = lipgloss.NewStyle()...
m.SetStyles(s)
```

Applies to: textarea, textinput, list, help, table.

---

## 9. Component sizes are methods now

**Symptom**: `cannot assign to m.Width (variable of type func() int)`.

| v1 (field) | v2 (method) |
|---|---|
| `m.Width = 40` | `m.SetWidth(40)` |
| `width := m.Width` | `width := m.Width()` |
| `m.Height = 20` | `m.SetHeight(20)` |
| `m.YOffset` (viewport) | `m.SetYOffset(n)` / `m.YOffset()` |

Applies to: viewport, table, textarea, help.

---

## 10. `viewport.New` takes options now

```go
// v1
vp := viewport.New(80, 20)

// v2
vp := viewport.New(viewport.WithWidth(80), viewport.WithHeight(20))
// or:
vp := viewport.New()
vp.SetWidth(80)
vp.SetHeight(20)
```

---

## 11. `spinner.Tick` is now an instance method

```go
// v1
return spinner.Tick  // package function

// v2
return m.spinner.Tick  // method
```

---

## 12. `textarea.Blink` exists; per-component Blink is per-instance

`textarea.Blink` is a package-level `tea.Cmd` for the textarea's cursor — still exported in v2. You return it from `Init`. The same applies to textinput.

```go
func (m model) Init() tea.Cmd {
    return textarea.Blink
}
```

---

## 13. Paste handling moved to dedicated message types

**Symptom**: `msg.Paste` is gone on KeyPressMsg.

```go
// v1
case tea.KeyMsg:
    if msg.Paste { … }

// v2
case tea.PasteMsg:
    m.text += msg.Content
case tea.PasteStartMsg:
case tea.PasteEndMsg:
```

---

## 14. `tea.Sequentially` → `tea.Sequence`

```go
// v1
tea.Sequentially(cmd1, cmd2)

// v2
tea.Sequence(cmd1, cmd2)
```

---

## 15. `AdaptiveColor` no longer in lipgloss core

**Symptom**: `lipgloss.AdaptiveColor` undefined.

```go
// v1
lipgloss.AdaptiveColor{Light: "#fff", Dark: "#000"}

// v2 — use compat package OR LightDark helper
compat.AdaptiveColor{Light: lipgloss.Color("#fff"), Dark: lipgloss.Color("#000")}
lipgloss.LightDark(isDark)(light, dark)
```

The recommended path is `LightDark` paired with `tea.RequestBackgroundColor` in `Init()`. See `styling.md`.

---

## 16. Streaming bg / empty rows don't fill

**Symptom**: You set `Base.Background` on textarea, but empty rows below the cursor still show the terminal's default bg. The colored background only appears on rows the user has typed on.

**Cause**: textarea renders content rows up to their logical width, but blank rows are just an EndOfBuffer marker (`~` by default).

**Fix**: when rendering the textarea inside a bordered style, set `.Width(n)` on the border style. Lip Gloss pads each line out to that width with the bg color, including the EndOfBuffer rows:

```go
parts = append(parts, styleInputBorder.Width(m.width - 4).Render(m.input.View()))
```

Also paint `EndOfBuffer` with bg-on-bg so the `~` glyphs disappear:

```go
hiddenBuf := lipgloss.NewStyle().Foreground(colorBg).Background(colorBg)
styles.Focused.EndOfBuffer = hiddenBuf
```

---

## 17. Shift+Enter only works on Kitty-protocol terminals

**Symptom**: You bind `shift+enter` to insert newline; works in Ghostty but submits as plain Enter in macOS Terminal.app and stock iTerm2.

**Cause**: Most terminals don't transmit `shift+enter` as a distinct sequence. Bubble Tea v2 supports the Kitty keyboard protocol; supported terminals send a unique code so v2 reports `"shift+enter"`. Non-supporting terminals collapse it into `"enter"`.

**Fix**: Bind BOTH `shift+enter` and a universal fallback like `ctrl+j`:

```go
ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("shift+enter", "ctrl+j"))
```

Document the fallback. Terminals that support it: Ghostty, Kitty, WezTerm, foot, Alacritty (recent), iTerm2 (with the keyboard-protocol opt-in).

---

## 18. Concurrent goroutines mutating shared model state → race

**Symptom**: Random crashes under high load, or `go test -race` reports a data race on a slice or map in your model.

**Cause**: Multiple goroutines (e.g., concurrent chat submits) calling methods on the same `*model` directly, bypassing the Bubble Tea event loop.

**Fix**: Goroutines must only `prog.Send(msg)` — never mutate model state. The event loop serializes all mutations inside `Update`.

If a goroutine needs to read model state, snapshot it before starting:

```go
func (m *model) submitCmd(prompt string) tea.Cmd {
    return func() tea.Msg {
        snapshot := append([]Msg(nil), m.sess.messages...) // copy
        go func() {
            result := callAPI(snapshot, prompt)
            m.prog.Send(resultMsg{result: result})
        }()
        return nil
    }
}
```

The TUI applies the result in Update, which is single-threaded.

---

## 19. `tea.WindowSizeMsg` fires once at startup, then on resize

**Symptom**: Layout works the first frame but breaks after resize, OR the initial frame is wrong sized.

**Fix**: Always handle `WindowSizeMsg` and recompute every layout-relevant size. Don't hardcode 80x24 in your model — the message fires at startup with the real dimensions.

```go
case tea.WindowSizeMsg:
    m.width, m.height = msg.Width, msg.Height
    m.viewport.SetWidth(msg.Width)
    m.viewport.SetHeight(msg.Height - footerHeight)
    m.input.SetWidth(msg.Width - 4)
```

---

## 20. `prog.Send` after Quit is a no-op (don't worry)

**Symptom**: Streaming goroutine still running when user hits Ctrl+C. Will it panic?

**No**. Bubble Tea v2 documents that `Send` after `Quit` is a no-op. The goroutine's `prog.Send(msg)` calls return silently after quit. You don't need to guard against it.

But the goroutine itself outlives `tea.Quit` until the underlying iterator (stream, channel) closes. If you spawn a goroutine that polls forever, **also pass a context** so you can cancel it on quit:

```go
ctx, cancel := context.WithCancel(context.Background())
defer cancel()
// goroutines use ctx.Done() to exit
```

---

## 21. `lipgloss.Width(s)` not `len(s)` for measuring rendered strings

**Symptom**: Right-align or padding math is off because ANSI escape sequences are counted as characters.

```go
// Wrong:
gap := width - len(left) - len(right)

// Right:
gap := width - lipgloss.Width(left) - lipgloss.Width(right)
```

`lipgloss.Width` strips ANSI escapes and counts visible cells. `lipgloss.Height` does the same for line count.

---

## 22. Border + Width math

**Symptom**: Bordered content overflows the terminal width by 4 cells.

**Cause**: `lipgloss.Border` adds 2 cells (1 per side). Padding adds more. Setting `Width(N)` sets the CONTENT area to N; total = N + 2*padding + 2 (border).

For a box that exactly fills the terminal:

```go
style := lipgloss.NewStyle().
    Border(lipgloss.RoundedBorder()).
    Padding(0, 1).         // 1-char horizontal padding
    Width(termWidth - 4)   // 2 padding + 2 border = 4
```

---

## 23. ASCII art / Braille glyphs: check the user's terminal font

**Symptom**: Your fancy Braille banner shows as `□□□` boxes on someone's terminal.

**Cause**: Braille block (U+2800–U+28FF) isn't in every monospace font.

**Fix**: Document the supported fonts (Menlo, SF Mono, JetBrains Mono, Fira Code, Cascadia all include Braille). If a user reports the issue, suggest a font change.

---

## 24. Default selection on a slash palette is destructive

**Symptom**: User types `/` and hits Enter, your TUI clears all their history.

**Cause**: You sorted your slash catalog alphabetically; `/clear` is first; the default selection on a bare `/` is the first item.

**Fix**: Put a harmless command first (`/help` is conventional). Alphabetize the rest. A bare `/` + Enter then runs help, which is benign and discoverable.

---

## 25. Quitting before Init's command runs

**Symptom**: You return `someCmd` from `Init()` but the program exits before its message lands.

**Cause**: The user pressed Ctrl+C immediately. The command was scheduled, but `Quit` took precedence.

**Fix**: This is expected and usually fine. Don't put critical setup in `Init` commands — put it in the model constructor before `tea.NewProgram(m)`.

---

## 26. Multiple `tea.Cmd` returns need `tea.Batch`

**Symptom**: Only one of your Init commands fires.

**Fix**: `tea.Batch(cmd1, cmd2, ...)` runs them concurrently. `tea.Sequence(cmd1, cmd2, ...)` runs them in order. Don't try to return a slice — there's no such API.

```go
func (m model) Init() tea.Cmd {
    return tea.Batch(textarea.Blink, m.spinner.Tick, tea.RequestBackgroundColor)
}
```

---

## 27. Color profile downsampling on non-TrueColor terminals

**Symptom**: Hex colors look wrong / muddy / wrong-channel on macOS Terminal.app or older iTerm2.

**Cause**: Those terminals are 256-color, not TrueColor. Lip Gloss downsamples your hex to the nearest 256-color value. Sometimes the nearest doesn't match what you envisioned.

**Fix**: For brand colors that need to be exact, prefer 256-color indices (e.g. `lipgloss.Color("82")` for accent green) over hex. They render identically across terminals. For everything else, trust the downsampler.

To force a profile (testing): `tea.NewProgram(m, tea.WithColorProfile(colorprofile.TrueColor))`.

---

## 28. `huh.Form` embedded in Bubble Tea: type assertion needed

**Symptom**: `cannot use form (type tea.Model) as type *huh.Form`.

```go
case msg:
    var cmd tea.Cmd
    f, cmd := m.form.Update(msg)
    m.form = f.(*huh.Form)  // type assertion required
    return m, cmd
```

`huh.Form.Update` returns the `tea.Model` interface; assert to the concrete pointer to keep storing it.

---

## See also

- `architecture.md` — the broader v2 model
- `components.md` — component-specific v2 changes
