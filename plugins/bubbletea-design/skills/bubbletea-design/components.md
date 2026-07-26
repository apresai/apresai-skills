# Components: Bubbles v2 catalog

Bubbles ships pre-built components that solve 80% of the TUI surface area. Default to using them; only roll your own when you've outgrown a specific bubble. Every component implements the Model interface (`Update`, `View`) and is meant to be embedded in your parent model.

Import path: `charm.land/bubbles/v2/<name>`. Constructor convention: `name.New(opts...)`.

## Quick map

| Component | Use it for |
|---|---|
| **textarea** | Multi-line input. Chat composer, editor pane, multi-paragraph forms. |
| **textinput** | Single-line input. Search bar, filter, single-field form. |
| **viewport** | Scrollable region. Chat transcript, log viewer, file content. Built-in mouse wheel. |
| **list** | Filterable selection list with custom delegates. App picker, command palette, file selector. |
| **table** | Tabular data with row selection. Schema viewer, leaderboard, file browser. |
| **spinner** | Animated "in progress" indicator. Multiple shapes (dot, line, pulse, globe, moon, …). |
| **progress** | Linear progress bar. Download, upload, generation. Supports gradients + animation. |
| **help** | Renders KeyMap as bottom-of-screen hint. Toggle short/full views. |
| **paginator** | Dots or "1/N" pagination. Pair with custom content rendering. |
| **filepicker** | Browse and pick local files. Built-in navigation. |
| **key** | `key.Binding` struct + `key.Matches` helper for unified keymaps. |
| **stopwatch** | Tracks elapsed time. Toggle start/stop, reset. |
| **timer** | Counts down from a duration. Tick events fire as it elapses. |
| **cursor** | Reusable blinking cursor primitive (used by textarea/textinput internally). |

---

## textarea

Multi-line input. Handles Unicode, pasting, vertical scroll inside the area, line numbers, virtual or terminal cursor.

```go
import "charm.land/bubbles/v2/textarea"

ta := textarea.New()
ta.Placeholder = "Type here…"
ta.SetWidth(60)
ta.SetHeight(10)
ta.ShowLineNumbers = false
ta.CharLimit = 0           // 0 = unlimited
ta.Focus()
```

**Key bindings**: `ta.KeyMap` is a struct of `key.Binding` values. Defaults via `textarea.DefaultKeyMap()` (now a function, not a variable). Common rebind. Change InsertNewline so bare Enter falls through to your dispatcher:

```go
ta.KeyMap.InsertNewline = key.NewBinding(key.WithKeys("shift+enter", "ctrl+j"))
// Now `enter` is unbound on the textarea and your Update can treat it as "submit".
```

**Styling**: `ta.Styles()` returns the current `textarea.Styles` (a struct of `StyleState` for Focused / Blurred + a `CursorStyle`). Mutate, then `SetStyles`:

```go
styles := ta.Styles()
styles.Focused.Base       = lipgloss.NewStyle().Background(lipgloss.Color("236"))
styles.Focused.Prompt     = lipgloss.NewStyle().Foreground(lipgloss.Color("82")).Bold(true)
styles.Focused.Placeholder = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
styles.Focused.EndOfBuffer = lipgloss.NewStyle().Foreground(lipgloss.Color("236")) // hide ~ gutter
ta.SetStyles(styles)
```

**Prompt as a left-edge bar**: set `ta.Prompt = "▌ "` and style its color via `styles.Focused.Prompt`. The same character is rendered on every line, so vertically they form a continuous bar.

**Init**: `textarea.Blink` (a `tea.Cmd`) starts the blinking cursor. Return it from `Init()`.

**Common methods**:
- `Value() string`, `SetValue(s)`
- `Focus() tea.Cmd`, `Blur()`, `Focused() bool`
- `Reset()` (clears content)
- `Line() int`, `Column() int` (1-indexed in your UI)
- `SetWidth(w)`, `SetHeight(h)`, `Width()`, `Height()`
- `LineCount() int`

---

## textinput

Single-line input with a virtual or terminal cursor, completion suggestions, masking.

```go
import "charm.land/bubbles/v2/textinput"

ti := textinput.New()
ti.Placeholder = "Search…"
ti.SetWidth(40)
ti.CharLimit = 0
ti.Prompt = "🔍 "
ti.Focus()
```

**Suggestions** (inline auto-complete):
```go
ti.SetSuggestions([]string{"apple", "banana", "cherry"})
ti.ShowSuggestions = true
```

Match against the prefix; the unmatched tail renders in `Styles.Suggestion`.

**Masking** (passwords): `ti.EchoMode = textinput.EchoPassword` and `ti.EchoCharacter = '•'`.

---

## viewport

Scrollable content region. Built-in mouse wheel, keyboard scroll (PgUp/PgDn, half-page Ctrl+U/Ctrl+D), soft-wrap, optional gutter (line numbers).

```go
import "charm.land/bubbles/v2/viewport"

vp := viewport.New(viewport.WithWidth(80), viewport.WithHeight(20))
vp.MouseWheelEnabled = true     // default
vp.MouseWheelDelta   = 3        // lines per wheel tick
vp.SetContent(longString)
vp.GotoBottom()
```

**Scroll programmatically**: `vp.GotoTop()`, `vp.GotoBottom()`, `vp.SetYOffset(n)`, `vp.ScrollUp(n)`, `vp.ScrollDown(n)`.

**Forward mouse + scroll keys** to viewport from your parent Update:

```go
case tea.MouseWheelMsg, tea.MouseClickMsg, tea.MouseReleaseMsg, tea.MouseMotionMsg:
    var cmd tea.Cmd
    m.viewport, cmd = m.viewport.Update(msg)
    return m, cmd

case tea.KeyPressMsg:
    switch msg.String() {
    case "pgup", "pgdown", "ctrl+u", "ctrl+d":
        var cmd tea.Cmd
        m.viewport, cmd = m.viewport.Update(msg)
        return m, cmd
    }
```

**Gutter** (line numbers, status icons):

```go
vp.LeftGutterFunc = func(info viewport.GutterContext) string {
    if info.Index >= info.TotalLines {
        return "   ~ │ "  // empty-line marker
    }
    return fmt.Sprintf("%4d │ ", info.Index+1)
}
```

**Style** (border around viewport):

```go
vp.Style = lipgloss.NewStyle().
    Border(lipgloss.RoundedBorder()).
    BorderForeground(lipgloss.Color("62"))
```

---

## list

A filterable, paginated selection list. The most flexible bubble: you provide `list.Item`s and a `list.ItemDelegate` that controls rendering.

```go
import "charm.land/bubbles/v2/list"

type item string
func (i item) FilterValue() string { return string(i) }

type itemDelegate struct{}
func (d itemDelegate) Height() int                             { return 1 }
func (d itemDelegate) Spacing() int                            { return 0 }
func (d itemDelegate) Update(_ tea.Msg, _ *list.Model) tea.Cmd { return nil }
func (d itemDelegate) Render(w io.Writer, m list.Model, index int, listItem list.Item) {
    i := listItem.(item)
    style := lipgloss.NewStyle().PaddingLeft(2)
    str := fmt.Sprintf("%d. %s", index+1, i)
    if index == m.Index() {
        style = style.Foreground(lipgloss.Color("170")).Bold(true)
        str = "▸ " + string(i)
    }
    fmt.Fprint(w, style.Render(str))
}

items := []list.Item{item("Foo"), item("Bar"), item("Baz")}
l := list.New(items, itemDelegate{}, 40, 20)
l.Title = "Pick one"
l.SetShowStatusBar(true)
l.SetFilteringEnabled(true)
```

**Key methods**:
- `SelectedItem() list.Item`: what's under the cursor
- `Index() int`: current cursor position
- `SetItems([]list.Item)`: replace contents
- `SetSize(w, h)`: resize on `tea.WindowSizeMsg`
- `ResetFilter()`

**Filtering** with `SetFilteringEnabled(true)`: press `/` to start filtering. Esc clears. Items whose `FilterValue()` matches are kept.

**Statusbar**: `SetShowStatusBar(true)` shows "5 items · filtered" at the bottom. Customize via `Styles.StatusBar`.

**For a simpler list** (no fuzzy filter, no statusbar), use a raw delegate with substring matching; see `patterns.md` for the model-picker recipe.

---

## table

Navigable tabular data with row selection.

```go
import "charm.land/bubbles/v2/table"

columns := []table.Column{
    {Title: "ID", Width: 5},
    {Title: "Name", Width: 20},
    {Title: "Status", Width: 12},
}
rows := []table.Row{
    {"1", "alice", "active"},
    {"2", "bob",   "idle"},
}

t := table.New(
    table.WithColumns(columns),
    table.WithRows(rows),
    table.WithFocused(true),
    table.WithHeight(10),
)

s := table.DefaultStyles()
s.Header   = s.Header.BorderStyle(lipgloss.NormalBorder()).BorderBottom(true).Bold(true)
s.Selected = s.Selected.Foreground(lipgloss.Color("229")).Background(lipgloss.Color("57")).Bold(true)
t.SetStyles(s)
```

**Selection**: `t.SelectedRow() table.Row` returns the current row (or nil).

**Resize on window resize**: `t.SetWidth(w)` and `t.SetHeight(h)`.

---

## spinner

Animated character cycle. Eight built-in styles.

```go
import "charm.land/bubbles/v2/spinner"

sp := spinner.New(spinner.WithSpinner(spinner.Dot))
sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("205"))

// In Init, return sp.Tick to start animating:
func (m model) Init() tea.Cmd { return m.spinner.Tick }

// In Update, forward spinner.TickMsg to the spinner:
case spinner.TickMsg:
    var cmd tea.Cmd
    m.spinner, cmd = m.spinner.Update(msg)
    return m, cmd
```

Built-in styles: `spinner.Line`, `spinner.Dot`, `spinner.Ellipsis`, `spinner.MiniDot`, `spinner.Pulse`, `spinner.Block`, `spinner.Globe`, `spinner.Moon`, `spinner.Monkey`.

Custom:
```go
spinner.New(spinner.WithSpinner(spinner.Spinner{
    Frames: []string{"⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈"},
    FPS:    time.Second / 8,
}))
```

**Stop a spinner**: just stop returning Tick from your Update. There's no explicit "stop" call: when the model decides it doesn't need the spinner anymore, drop the `case spinner.TickMsg` handler or stop returning its Cmd.

---

## progress

Linear progress bar with optional gradient or per-cell color function.

```go
import "charm.land/bubbles/v2/progress"

// Solid color:
p := progress.New(progress.WithColors(lipgloss.Color("#7571F9")), progress.WithWidth(40))

// Gradient that scales with fill:
p := progress.New(progress.WithDefaultBlend(), progress.WithWidth(40), progress.WithScaled(true))

// Custom per-cell colors:
p := progress.New(progress.WithColorFunc(func(total, current float64) color.Color {
    if current/total < 0.5 {
        return lipgloss.Color("#FF0000")
    }
    return lipgloss.Color("#00FF00")
}))

// Render at a percentage 0.0-1.0:
fmt.Println(p.ViewAs(0.42))
```

**Animation**: progress doesn't tick itself. For animated fill, drive it with `tea.Tick` (see `architecture.md`). To animate the bar's internal "ease" effect (it has spring physics):

```go
case progress.FrameMsg:
    var cmd tea.Cmd
    m.progress, cmd = m.progress.Update(msg)
    return m, cmd

// And kick off the animation:
cmd := m.progress.SetPercent(0.75)  // returns a Cmd that animates to 75%
```

---

## help

Renders a `KeyMap` as a help line. Toggles short ↔ full.

```go
import (
    "charm.land/bubbles/v2/help"
    "charm.land/bubbles/v2/key"
)

type keyMap struct {
    Up, Down, Help, Quit key.Binding
}

func (k keyMap) ShortHelp() []key.Binding {
    return []key.Binding{k.Help, k.Quit}
}
func (k keyMap) FullHelp() [][]key.Binding {
    return [][]key.Binding{
        {k.Up, k.Down},
        {k.Help, k.Quit},
    }
}

var keys = keyMap{
    Up:   key.NewBinding(key.WithKeys("up", "k"),    key.WithHelp("↑/k", "up")),
    Down: key.NewBinding(key.WithKeys("down", "j"),  key.WithHelp("↓/j", "down")),
    Help: key.NewBinding(key.WithKeys("?"),          key.WithHelp("?", "help")),
    Quit: key.NewBinding(key.WithKeys("q", "esc"),   key.WithHelp("q", "quit")),
}

h := help.New()
h.Styles = help.DefaultStyles(true)
// In Update on `?`:
m.help.ShowAll = !m.help.ShowAll
// In View:
m.help.View(keys)
```

---

## key

Unified key bindings with help text. `key.NewBinding(opts...)` constructs a `key.Binding`; `key.Matches(msg, binding)` checks if a `KeyPressMsg` triggers it. The `help` bubble reads `WithHelp(...)` to build the help line.

```go
b := key.NewBinding(
    key.WithKeys("ctrl+s"),
    key.WithHelp("ctrl+s", "save"),
)

case tea.KeyPressMsg:
    if key.Matches(msg, b) {
        return m, save()
    }
```

`key.Binding` also supports `WithDisabled(bool)` to grey out a binding contextually.

---

## paginator

```go
import "charm.land/bubbles/v2/paginator"

p := paginator.New()
p.Type = paginator.Dots          // or paginator.Arabic for "1/5"
p.PerPage = 5
p.SetTotalPages(len(items))
p.ActiveDot   = "●"
p.InactiveDot = "○"

start, end := p.GetSliceBounds(len(items))   // visible slice indices
for _, it := range items[start:end] {
    // render it
}

// In Update, forward left/right keys:
case tea.KeyPressMsg:
    switch msg.String() {
    case "left", "h":  p.PrevPage()
    case "right", "l": p.NextPage()
    }
```

Render the pagination indicator:

```go
fmt.Println(p.View())  // "● ○ ○ ○ ○" or "2/5"
```

---

## filepicker

Browse and pick files from the local filesystem.

```go
import "charm.land/bubbles/v2/filepicker"

fp := filepicker.New()
fp.AllowedTypes = []string{".md", ".txt", ".pdf"}
fp.CurrentDirectory, _ = os.UserHomeDir()
fp.ShowHidden = false
fp.SetHeight(20)

// In Update:
var cmd tea.Cmd
m.filepicker, cmd = m.filepicker.Update(msg)

// Did the user select something?
if didSelect, path := m.filepicker.DidSelectFile(msg); didSelect {
    m.selected = path
}
```

---

## stopwatch

```go
import "charm.land/bubbles/v2/stopwatch"

sw := stopwatch.New(stopwatch.WithInterval(time.Millisecond * 100))

func (m model) Init() tea.Cmd {
    return m.stopwatch.Init()  // starts ticking
}

// In Update:
case tea.KeyPressMsg:
    switch msg.String() {
    case " ": return m, m.stopwatch.Toggle()
    case "r": return m, m.stopwatch.Reset()
    }
case stopwatch.TickMsg, stopwatch.StartStopMsg, stopwatch.ResetMsg:
    var cmd tea.Cmd
    m.stopwatch, cmd = m.stopwatch.Update(msg)
    return m, cmd

// View:
fmt.Println(m.stopwatch.View())  // "0:01.4"
```

---

## timer

Countdown variant. Same API shape as stopwatch:

```go
import "charm.land/bubbles/v2/timer"

t := timer.New(30 * time.Second, timer.WithInterval(time.Millisecond * 100))

func (m model) Init() tea.Cmd { return m.timer.Init() }

case timer.TickMsg:
    var cmd tea.Cmd
    m.timer, cmd = m.timer.Update(msg)
    if m.timer.Timedout() { return m, tea.Quit }
    return m, cmd
```

---

## cursor

The underlying blinking cursor primitive. Most apps don't use it directly; textinput and textarea embed it. If you build your own input widget, this is what you'd embed.

```go
import "charm.land/bubbles/v2/cursor"

c := cursor.New()
c.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("82"))
c.SetChar("█")  // or use the default block cursor
```

---

## Bonus: huh (forms)

`charm.land/huh/v2` is a separate library (not part of bubbles) for building forms: input groups with validation, multi-step flows, accessible mode for screen readers. It can be used standalone OR embedded in a Bubble Tea model.

```go
import "charm.land/huh/v2"

var (
    name string
    role string
)

form := huh.NewForm(
    huh.NewGroup(
        huh.NewInput().
            Title("Your name?").
            Value(&name).
            Validate(func(s string) error {
                if s == "" { return errors.New("required") }
                return nil
            }),
        huh.NewSelect[string]().
            Title("Role").
            Options(
                huh.NewOption("Admin", "admin"),
                huh.NewOption("User", "user"),
            ).
            Value(&role),
    ),
)

if err := form.Run(); err != nil {
    log.Fatal(err)
}
fmt.Printf("Hello, %s (%s)\n", name, role)
```

Field types: `Input`, `Text` (multi-line), `Select`, `MultiSelect`, `Confirm`, `Note`, `FilePicker`. Groups support `WithCondition` for branching flows.

**Embedding in Bubble Tea**: the form's `Update` and `View` follow the standard contract; embed a `huh.Form` in your model field and forward msgs the way you would any other component.

---

## Picking a component checklist

| You need… | Use this |
|---|---|
| Type one short string | `textinput` |
| Type multi-line text (code, message, prompt) | `textarea` |
| Scrollable list of styled output | `viewport` |
| Pick one item from a filterable list | `list` |
| Pick one row from a tabular dataset | `table` |
| "I'm working" indicator (small) | `spinner` |
| Progress to a known completion (download, gen) | `progress` |
| Show keybinds at the bottom of the screen | `help` |
| Page through 100s of items | `paginator` |
| Pick a file from disk | `filepicker` |
| Multi-field form with validation | `huh` |
| Build the keymap once, use for input + help | `key` |

## See also

- `patterns.md`: full recipes that combine these components (chat REPL with viewport + textarea + footer, etc.)
- `gotchas.md`: v1→v2 changes per component (constructors, KeyMap-as-function, field-to-method renames)
