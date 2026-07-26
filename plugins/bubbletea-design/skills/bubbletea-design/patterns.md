# Patterns: TUI recipes

Concrete, copy-pasteable patterns for the layouts that show up in 90% of TUIs. Each recipe ships with: the user-facing shape, the model struct, the Update routing, and the styling notes. Adapt these instead of inventing from scratch.

## Pattern 1: Chat REPL with sticky footer

The shape Claude Code and grok-chat use. Scrollable transcript on top, bordered input box in the middle, two-row status footer on the bottom.

```
┌─────────────────────────────────────────────────────┐
│ > what's the weather                                │
│ Cool and rainy in your area…                        │  ← scrollable viewport
│                                                     │
├─────────────────────────────────────────────────────┤
│ > █                                                 │  ← bordered textarea
├─────────────────────────────────────────────────────┤
│ [bar] 12%  grok-4.3  (1.0M)  4,521↑ 1,830↓   hint   │  ← row 1: left+right
│ last: +412↑ +180↓  $0.001 · session $0.04           │  ← row 2: deltas
└─────────────────────────────────────────────────────┘
```

### Model

```go
type model struct {
    ctx       context.Context
    prog      *tea.Program
    viewport  viewport.Model
    input     textarea.Model
    width     int
    height    int

    transcript []turn
    inflight   int
    nextTurnID int64
}

type turn struct {
    role   string  // "user" | "assistant" | "info" | "error"
    text   string
    turnID int64
}
```

### Update

```go
func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.WindowSizeMsg:
        m.width, m.height = msg.Width, msg.Height
        m.relayout()
        return m, nil

    case tea.KeyPressMsg:
        return m.handleKey(msg)

    case tea.MouseWheelMsg, tea.MouseClickMsg, tea.MouseReleaseMsg, tea.MouseMotionMsg:
        var cmd tea.Cmd
        m.viewport, cmd = m.viewport.Update(msg)
        return m, cmd

    case deltaMsg:
        // Route delta to the assistant turn matching turnID.
        for i := range m.transcript {
            t := &m.transcript[i]
            if t.turnID == msg.turnID && t.role == "assistant" {
                t.text += msg.text
                break
            }
        }
        m.refreshViewport()
        return m, nil

    case doneMsg:
        m.inflight--
        m.refreshViewport()
        return m, nil
    }
    return m, nil
}

func (m *model) handleKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
    switch msg.String() {
    case "ctrl+c", "ctrl+d":
        return m, tea.Quit
    case "pgup", "pgdown", "ctrl+u":
        var cmd tea.Cmd
        m.viewport, cmd = m.viewport.Update(msg)
        return m, cmd
    case "enter":
        value := strings.TrimSpace(m.input.Value())
        if value == "" {
            return m, nil
        }
        m.input.Reset()
        return m.dispatchInput(value)
    }
    var cmd tea.Cmd
    m.input, cmd = m.input.Update(msg)
    return m, cmd
}
```

### Dispatch + streaming goroutine

```go
func (m *model) dispatchInput(value string) (tea.Model, tea.Cmd) {
    m.nextTurnID++
    id := m.nextTurnID
    m.transcript = append(m.transcript,
        turn{role: "user", text: value, turnID: id},
        turn{role: "assistant", text: "", turnID: id},
    )
    m.inflight++
    m.refreshViewport()
    return m, m.submitCmd(id, value)
}

func (m *model) submitCmd(id int64, prompt string) tea.Cmd {
    return func() tea.Msg {
        go func() {
            for delta := range streamFromAPI(m.ctx, prompt) {
                m.prog.Send(deltaMsg{turnID: id, text: delta})
            }
            m.prog.Send(doneMsg{turnID: id})
        }()
        return nil
    }
}
```

### View

```go
func (m *model) View() tea.View {
    parts := []string{
        m.viewport.View(),
        styleInputBorder.Width(m.width - 4).Render(m.input.View()),
        m.renderFooter(),
    }
    v := tea.NewView(lipgloss.JoinVertical(lipgloss.Left, parts...))
    v.AltScreen = true
    v.MouseMode = tea.MouseModeCellMotion
    return v
}

func (m *model) renderFooter() string {
    leftRow1  := fmt.Sprintf("[bar] %d%%  %s  %d↑ %d↓", m.contextPct(), m.model, m.totalIn, m.totalOut)
    leftRow2  := fmt.Sprintf("last: +%d↑ +%d↓ $%.4f · session $%.4f", m.lastIn, m.lastOut, m.lastCost, m.totalCost)
    rightRow1 := styleHint.Render("↵ send · ⇧↵ newline · / commands · /exit")
    if m.inflight > 0 {
        rightRow1 = styleAccent.Render(fmt.Sprintf("⏳ %d working…", m.inflight))
    }
    return leftRight(m.width, leftRow1, rightRow1) + "\n" + leftRow2
}
```

### relayout

```go
func (m *model) relayout() {
    inputW := m.width - 4 // 2 for border, 2 for padding
    m.input.SetWidth(inputW)
    inputH := m.input.Height()
    vpH := m.height - 2 /*footer*/ - inputH - 2 /*border*/
    if vpH < 3 { vpH = 3 }
    m.viewport.SetWidth(m.width)
    m.viewport.SetHeight(vpH)
}
```

### Why this works

- **`turnID` linking** keeps deltas matched to the right turn even with concurrent submits.
- **`prog.Send` from goroutine** is the only safe way to stream into the event loop; recursive `tea.Cmd` doesn't work for blocking iterators.
- **Bordered input + filled background** anchors the eye; the input is the "you are here" affordance.
- **Two-row footer with left+right** halves the vertical cost vs three rows.

---

## Pattern 2: Slash-command palette

Type `/` to open a filterable list above the input. Up/Down to navigate, Tab to complete, Enter to run, Esc to dismiss.

### Model addition

```go
type slashCmd struct {
    name        string  // "/model"
    description string
    takesArg    bool    // true → completing inserts "/cmd " (with trailing space)
}

var slashCatalog = []slashCmd{
    {"/help",   "list slash commands",                          false},
    {"/clear",  "drop conversation history",                    false},
    {"/exit",   "exit",                                         false},
    {"/model",  "switch chat model: no arg lists models",       true},
    {"/search", "multi-agent web search",                       true},
    {"/image",  "generate an image",                            true},
    {"/status", "reprint the footer line",                      false},
}

type palette struct {
    open     bool
    matches  []slashCmd
    selected int
}
```

### Palette logic

```go
func (p *palette) recompute(input string) {
    q := strings.ToLower(input)
    p.matches = p.matches[:0]
    for _, c := range slashCatalog {
        if strings.HasPrefix(c.name, q) {
            p.matches = append(p.matches, c)
        }
    }
    if p.selected >= len(p.matches) { p.selected = 0 }
}

func (p *palette) move(delta int) {
    if len(p.matches) == 0 { return }
    p.selected = (p.selected + delta + len(p.matches)) % len(p.matches)
}

func (p *palette) current() (slashCmd, bool) {
    if p.selected < 0 || p.selected >= len(p.matches) { return slashCmd{}, false }
    return p.matches[p.selected], true
}
```

### Open/close logic

```go
// After every textarea update:
func (m *model) refreshPalette() {
    v := m.input.Value()
    wasOpen := m.pal.open
    if strings.HasPrefix(v, "/") && !strings.ContainsRune(v, ' ') {
        m.pal.open = true
        m.pal.recompute(v)
    } else {
        m.pal.open = false
    }
    if m.pal.open != wasOpen {
        m.relayout()
    }
}
```

### Key routing

```go
if m.pal.open && len(m.pal.matches) > 0 {
    switch msg.String() {
    case "up":   m.pal.move(-1); return m, nil
    case "down": m.pal.move(1);  return m, nil
    case "esc":  m.pal.open = false; return m, nil
    case "tab":  return m.completePalette(false)
    case "enter": return m.completePalette(true)
    }
}
```

```go
func (m *model) completePalette(runIfNoArg bool) (tea.Model, tea.Cmd) {
    cmd, ok := m.pal.current()
    if !ok { m.pal.open = false; return m, nil }
    if !cmd.takesArg && runIfNoArg {
        m.input.Reset()
        m.pal.open = false
        return m.dispatchInput(cmd.name)  // runs immediately
    }
    text := cmd.name
    if cmd.takesArg { text += " " }
    m.input.SetValue(text)
    m.pal.open = false
    return m, nil
}
```

### Render the palette

```go
func (p *palette) render(width int) string {
    nameWidth := 0
    for _, c := range p.matches {
        if w := lipgloss.Width(c.name); w > nameWidth { nameWidth = w }
    }
    var b strings.Builder
    for i, c := range p.matches {
        if i > 0 { b.WriteString("\n") }
        marker := "  "
        name := stylePaletteCmd.Render(padRight(c.name, nameWidth))
        if i == p.selected {
            marker = stylePaletteMark.Render("▸ ")
            name = stylePaletteSel.Render(padRight(c.name, nameWidth))
        }
        fmt.Fprintf(&b, "%s%s  %s", marker, name, stylePaletteDesc.Render(c.description))
    }
    return b.String()
}
```

Render in `View()` between viewport and input. Add `palHeight()` to relayout math so the viewport shrinks when the palette is open.

### Design notes

- Put a **harmless first entry** in the catalog (e.g. `/help`). When the user types `/` + Enter without navigating, that's what runs. Destructive defaults are an easy footgun otherwise.
- **Prefix-match, not fuzzy** for command palettes: predictability beats power here.
- **Tab completes; Enter runs**. Tab is "fill into input"; Enter is "go".

---

## Pattern 3: Modal picker (model/file/option selection)

Different from the slash palette: opens in response to a command, takes over the screen until dismissed.

```go
type modelPicker struct {
    open     bool
    items    []string
    filter   string
    visible  []string
    selected int
}

func (p *modelPicker) recompute() {
    p.visible = p.visible[:0]
    q := strings.ToLower(p.filter)
    for _, m := range p.items {
        if q == "" || strings.Contains(strings.ToLower(m), q) {
            p.visible = append(p.visible, m)
        }
    }
    if p.selected >= len(p.visible) { p.selected = 0 }
}
```

### Routing

The picker is **modal**: it captures every key while open. Insert this BEFORE the regular palette/textarea routing:

```go
if m.modelPicker.open {
    switch msg.String() {
    case "up":        m.modelPicker.move(-1); return m, nil
    case "down":      m.modelPicker.move(1);  return m, nil
    case "esc":       m.modelPicker.reset();  m.relayout(); return m, nil
    case "enter":
        if sel, ok := m.modelPicker.current(); ok {
            m.sess.model = sel
            m.modelPicker.reset()
        }
        m.relayout()
        return m, nil
    case "backspace", "delete":
        if r := []rune(m.modelPicker.filter); len(r) > 0 {
            m.modelPicker.filter = string(r[:len(r)-1])
            m.modelPicker.recompute()
        }
        return m, nil
    }
    // Printable runes extend the filter.
    if t := msg.Key().Text; t != "" {
        m.modelPicker.filter += t
        m.modelPicker.recompute()
    }
    return m, nil
}
```

The picker is open ⇒ NO keys go to the textarea. This is the modal contract.

---

## Pattern 4: Dashboard with multi-pane layout

Three or four bordered panes filling the terminal. Each pane is its own component (or just styled content).

```go
func (m *model) View() tea.View {
    sidebar := lipgloss.NewStyle().
        Width(m.width / 4).
        Height(m.height - 2).
        Border(lipgloss.NormalBorder()).
        Padding(1).
        Render(m.renderSidebar())

    main := lipgloss.NewStyle().
        Width(m.width - m.width/4 - 2).
        Height(m.height - 2).
        Border(lipgloss.NormalBorder()).
        Padding(1).
        Render(m.renderMain())

    body := lipgloss.JoinHorizontal(lipgloss.Top, sidebar, main)
    footer := m.renderFooter()
    return tea.NewView(lipgloss.JoinVertical(lipgloss.Left, body, footer))
}
```

**Focus**: track which pane is active in the model. Tab cycles. Only the focused pane receives keystrokes. Style the focused pane's border in the accent color, others in grey.

---

## Pattern 5: Async tasks with inflight indicator

When you have N concurrent background operations (chat, search, image, video) and want a single indicator:

```go
type model struct {
    inflight int
}

// Each async dispatch:
m.inflight++
return m, cmdThatSendsResultLater()

// Each completion:
case taskDoneMsg:
    m.inflight--
    // … process result …

// Footer indicator:
if m.inflight > 0 {
    label := "⏳ working…"
    if m.inflight > 1 {
        label = fmt.Sprintf("⏳ %d working…", m.inflight)
    }
    line = styleAccent.Render(label)
}
```

---

## Pattern 6: Live streaming from a writer (search, image, log tail)

When a function writes status to an `io.Writer` as it runs, and you want each write to appear in the TUI as it happens:

```go
type liveWriter struct {
    prog *tea.Program
    kind string  // "search-info" | "search-content" | "image-info"
}

func (w *liveWriter) Write(p []byte) (int, error) {
    if len(p) == 0 { return 0, nil }
    w.prog.Send(eventMsg{kind: w.kind, text: string(p)})
    return len(p), nil
}

// Dispatch:
func (m *model) searchCmd(query string) tea.Cmd {
    return func() tea.Msg {
        go func() {
            statusW  := &liveWriter{prog: m.prog, kind: "search-info"}
            contentW := &liveWriter{prog: m.prog, kind: "search-content"}
            err := runSearch(m.ctx, query, statusW, contentW)
            m.prog.Send(searchDoneMsg{err: err})
        }()
        return nil
    }
}

// Update:
case eventMsg:
    text := strings.TrimRight(msg.text, "\n")
    if text == "" { return m, nil }
    if msg.kind == "search-content" {
        // Stream into the last assistant turn
        if n := len(m.transcript); n > 0 && m.transcript[n-1].role == "assistant" {
            m.transcript[n-1].text += msg.text
        }
    } else {
        m.transcript = append(m.transcript, turn{role: "info", text: text})
    }
    m.refreshViewport()
```

This is how grok-chat surfaces the Captain/Harper/Lucas persona events live during `/search` instead of dumping them all at once at the end.

---

## Pattern 7: Empty-state banner

When the transcript is empty (fresh launch or after `/clear`), show a centered ASCII banner with a tagline. Use `chafa` to convert a logo PNG to Braille:

```sh
chafa --symbols=braille --fg-only --colors=none --size=80x20 --preprocess=on \
      --format=symbols assets/logo.png | sed '/^[⠀ ]*$/d'
```

Paste the output into a constant:

```go
const grokBanner = `⠀⠀⠀⠀⠀⠀⠀⢀⢀⢀⢀⢀⠀⠀⠀⠀⠀⠀⠀⠀⡀⡂⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠰⠰⠰⠰⠰⠰⠀⠀⠀⠀⠀⠀⠀⠆⠀⠀⠀⠀⠀⠀
…`

func renderBanner(width, height int) string {
    art := styleAccent.Render(grokBanner)
    tag := styleDim.Render("subscription chat with xAI Grok")
    block := lipgloss.JoinVertical(lipgloss.Center, art, "", tag)
    return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, block)
}
```

In `renderTranscript`, branch on length:

```go
if len(m.transcript) == 0 {
    return renderBanner(m.viewport.Width(), m.viewport.Height())
}
// … normal transcript rendering …
```

---

## Pattern 8: Form wizard with huh

Multi-step form with validation, branching, and accessible mode:

```go
import "charm.land/huh/v2"

var (
    project string
    runtime string
    deploy  bool
)

form := huh.NewForm(
    huh.NewGroup(
        huh.NewInput().
            Title("Project name").
            Value(&project).
            Validate(func(s string) error {
                if len(s) < 3 { return errors.New("at least 3 chars") }
                return nil
            }),
    ),
    huh.NewGroup(
        huh.NewSelect[string]().
            Title("Runtime").
            Options(
                huh.NewOption("Go 1.26", "go1.26"),
                huh.NewOption("Node 22 LTS", "node22"),
            ).
            Value(&runtime),
        huh.NewConfirm().
            Title("Deploy on save?").
            Affirmative("Yes").
            Negative("No").
            Value(&deploy),
    ),
)

if err := form.Run(); err != nil {
    log.Fatal(err)
}
```

**Branching**: `huh.NewGroup(...).WithCondition(func() bool { return deploy })` makes a group appear only if the prior selection met the condition.

To embed in a Bubble Tea app instead of running standalone, treat the form like any other component: it has `Update` and `View`:

```go
type model struct {
    form *huh.Form
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    var cmd tea.Cmd
    f, cmd := m.form.Update(msg)
    m.form = f.(*huh.Form)
    if m.form.State == huh.StateCompleted {
        return m, tea.Quit
    }
    return m, cmd
}

func (m *model) View() tea.View {
    return tea.NewView(m.form.View())
}
```

---

## Pattern 9: Long-running token-refresh / heartbeat goroutine

Background loops that need to fire occasionally without blocking the event loop:

```go
type refreshErrMsg struct{ err error }

// Start in your runApp wrapper, NOT in Init:
func runApp() error {
    m := newModel(ctx)
    p := tea.NewProgram(m)
    m.prog = p
    errs := make(chan error, 4)
    go heartbeat(ctx, errs)
    go drainErrs(p, errs)
    _, err := p.Run()
    return err
}

func heartbeat(ctx context.Context, errs chan<- error) {
    t := time.NewTicker(time.Minute)
    defer t.Stop()
    for {
        select {
        case <-ctx.Done():
            return
        case <-t.C:
            if err := refresh(); err != nil {
                select { case errs <- err: default: } // non-blocking
            }
        }
    }
}

func drainErrs(p *tea.Program, errs <-chan error) {
    for err := range errs {
        p.Send(refreshErrMsg{err: err})
    }
}

// In Update:
case refreshErrMsg:
    m.appendTurn(turn{role: "info", text: fmt.Sprintf("(refresh: %v)", msg.err)})
    return m, nil
```

The non-blocking send (`select { case errs <- err: default: }`) prevents the heartbeat from stalling if the drain goroutine is slow.

---

## Pattern 10: Tile-based animation (loading screen, spinner array)

Use `tea.Tick` to drive a frame counter:

```go
type frameMsg time.Time

func tick() tea.Cmd {
    return tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
        return frameMsg(t)
    })
}

func (m model) Init() tea.Cmd { return tick() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg.(type) {
    case frameMsg:
        m.frame++
        return m, tick()
    }
    return m, nil
}

func (m model) View() tea.View {
    chars := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
    return tea.NewView(chars[m.frame%len(chars)] + " Loading…")
}
```

For more sophisticated easing, see `charm.land/harmonica` (spring physics for smooth interpolation).

---

---

## Pattern 11: Multi-step wizard with step enum

An 8-step wizard where each step is a distinct UI state. Used in `~/dev/gimage/internal/tui/generate_flow.go` for the image generation flow. Works equally well for onboarding, form collection, or anything that forces a linear path.

### Shape

```
Step 1: Prompt textarea  →  Step 2: Provider picker  →  Step 3: Size picker
→  Step 4: Style picker  →  Step 5: Advanced options (multi-field, Tab cycling)
→  Step 6: Output path   →  Step 7: Command preview  →  Step 8: Progress + result
```

### Model

```go
type Step int

const (
    StepPrompt Step = iota
    StepProvider
    StepSize
    StepAdvanced
    StepOutput
    StepPreview
    StepProgress
    StepResult
)

type model struct {
    currentStep Step
    width, height int

    // One field per step that needs a component
    promptArea  textarea.Model
    outputInput textinput.Model
    progressBar progress.Model

    // Picker state (pure int index + slice of options)
    providers       []providerOption
    selectedProvider int

    // Result state
    resultPath string
    err        error
}
```

### Update routing

```go
func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    // Global keys first
    switch msg := msg.(type) {
    case tea.KeyPressMsg:
        switch msg.String() {
        case "ctrl+c":
            return m, tea.Quit
        case "esc":
            if m.currentStep > StepPrompt {
                m.currentStep--
                m.resetFocusForStep()
            }
            return m, nil
        }
    case tea.WindowSizeMsg:
        m.width, m.height = msg.Width, msg.Height
        return m, nil
    case generationCompleteMsg:
        m.currentStep = StepResult
        m.resultPath, m.err = msg.path, msg.err
        return m, nil
    }

    // Delegate to the active step
    switch m.currentStep {
    case StepPrompt:    return m.updatePrompt(msg)
    case StepProvider:  return m.updateProvider(msg)
    case StepAdvanced:  return m.updateAdvanced(msg)
    case StepProgress:  return m.updateProgress(msg)
    }
    return m, nil
}
```

### View: center each step in the terminal

```go
func (m *model) View() tea.View {
    var content string
    switch m.currentStep {
    case StepPrompt:   content = m.viewPrompt()
    case StepProvider: content = m.viewProvider()
    // … etc
    }
    v := tea.NewView(content)
    v.AltScreen = true
    return v
}

func (m *model) viewPrompt() string {
    box := focusedBoxStyle.Width(76).Render(
        titleStyle.Render("Step 1 / 8: Describe your image") + "\n\n" +
        m.promptArea.View() + "\n\n" +
        helpStyle.Render("Enter: next • Shift+Enter: newline • Esc: back • ?: help"),
    )
    return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}
```

`lipgloss.Place` centers the fixed-width box regardless of terminal size. No relayout math needed per step.

### Backtrack-safe focus reset

```go
func (m *model) resetFocusForStep() {
    switch m.currentStep {
    case StepPrompt:   m.promptArea.Focus()
    case StepAdvanced: m.blurAllAdvanced(); m.focusAdvanced(0)
    case StepOutput:   m.outputInput.Focus()
    }
}
```

### Why this works

- **Single `currentStep` int** keeps routing trivial. No nested state machines.
- **Esc always goes back one step**: consistent, no surprise exits.
- **`lipgloss.Place` for centering** means each step can have its own fixed width box; no global relayout.
- **Multi-field Tab cycling** in advanced steps: see gotcha #30 for the blur-all pattern.
- **`generationCompleteMsg`** is sent from a goroutine via `prog.Send` (see Pattern 1's streaming idiom). Never block the event loop during generation.

---

## Pattern 12: AltScreen vs inline (decision guide)

| Shape | Use AltScreen | Use Inline |
|---|---|---|
| Full-screen TUI (chat REPL, dashboard, file picker, wizard) | Yes | No |
| Short-lived prompt (picker, confirm, form with 1-3 fields) | No | Yes |
| Log tail that scrolls forever | Yes | No |
| Tool that prints structured output to stdout after interaction | No | Yes |
| Embeds in a shell pipeline (`cmd \| your-tui \| cmd`) | No | Yes |
| Needs the terminal's scrollback buffer | No | Yes |

**AltScreen** (`v.AltScreen = true` in View): takes over the full terminal, hides scrollback, restores on exit. User sees only your TUI. Correct for anything that should feel like an application.

**Inline** (default when `v.AltScreen` is false): renders below the shell prompt, uses the terminal's own scrollback. Correct for short confirmations or for tools that need to print their output so it's accessible after the TUI exits.

**Switching at runtime**: set `v.AltScreen` based on model state. You can enter and exit alt-screen mid-session (e.g., open a picker over the shell prompt, close it on selection, print the result inline).

```go
func (m model) View() tea.View {
    v := tea.NewView(m.render())
    v.AltScreen = m.pickerOpen  // dynamic: only full-screen during picker
    return v
}
```

**Performance note**: Bubble Tea v2 uses Synchronized Output (Mode 2026) automatically on terminals that support it (Ghostty, Kitty, WezTerm, recent iTerm2). This eliminates tearing for high-throughput log viewers regardless of AltScreen vs inline.

---

## Pattern 13: Testing TUIs with teatest

`teatest` lives at `github.com/charmbracelet/x/exp/teatest`. It wraps your model in a test harness, lets you send keystrokes, and provides golden-file snapshot helpers.

### Setup

```go
import (
    "testing"
    "time"

    tea "charm.land/bubbletea/v2"
    "github.com/charmbracelet/x/exp/teatest"
)

func TestModel_Quit(t *testing.T) {
    tm := teatest.NewTestModel(
        t,
        initialModel(),
        teatest.WithInitialTermSize(80, 24),
    )

    // Simulate pressing 'q'
    tm.Send(tea.KeyPressMsg{Code: 'q'})

    // Wait for the program to exit
    tm.WaitFinished(t, teatest.WithFinalTimeout(time.Second))
}
```

### Simulate keypresses

```go
// Press a single key
tm.Send(tea.KeyPressMsg{Code: 'j'})   // down
tm.Send(tea.KeyPressMsg{Code: tea.KeyEnter})

// Type a string (one keypress per rune)
for _, r := range "hello" {
    tm.Send(tea.KeyPressMsg{Code: r, Text: string(r)})
}

// Ctrl+C
tm.Send(tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl})
```

### Golden-file snapshot

```go
func TestModel_Golden(t *testing.T) {
    tm := teatest.NewTestModel(
        t,
        initialModel(),
        teatest.WithInitialTermSize(80, 24),
    )

    // Wait until the model renders something specific
    teatest.WaitFor(t, tm.Output(), func(b []byte) bool {
        return strings.Contains(string(b), "Select Provider")
    }, teatest.WithDuration(3*time.Second))

    // Snapshot current output against golden file
    // Run with -update to regenerate: go test ./... -update
    tm.RequireEqualOutput(t)
}
```

Golden files are stored in `testdata/` next to your `_test.go` file. Regenerate with `go test ./... -update`.

**CI gotcha**: golden files contain ANSI escape sequences that vary by color profile. Either generate them in CI (not locally) or force a fixed profile; see gotcha #32.

### WaitFor: poll until output matches

```go
teatest.WaitFor(
    t,
    tm.Output(),
    func(b []byte) bool {
        return strings.Contains(string(b), "done")
    },
    teatest.WithDuration(5*time.Second),
    teatest.WithCheckInterval(100*time.Millisecond),
)
```

Use `WaitFor` whenever your model has async operations (streaming, generation). Don't sleep.

---

## See also

- `architecture.md`: the runtime model that makes these patterns work
- `components.md`: every bubble used here
- `gotchas.md`: what'll break if you forget a v2 import path or msg type
- `design.md`: the why behind the visual choices (color, spacing, alignment)
