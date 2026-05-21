# Architecture — Bubble Tea v2

The Elm pattern, message routing, command pattern, and the few non-obvious patterns (streaming, ticking, modal state) that turn a toy TUI into a production app.

## The Model interface

Every Bubble Tea app implements three methods:

```go
type Model interface {
    Init() Cmd                          // first command after the model is constructed
    Update(Msg) (Model, Cmd)            // handle one message, return new model + optional command
    View() View                          // render the model as a tea.View (string + flags)
}
```

The runtime calls `Init()` once, then loops on `Update → View → Update`. Messages come from:
- the terminal (`tea.KeyPressMsg`, `tea.MouseClickMsg`, `tea.WindowSizeMsg`, etc.)
- commands returned from `Init()` / `Update()` (they return a `Msg` when they finish)
- `(*tea.Program).Send(msg)` from any goroutine

**Pattern**: use a struct as the model. Methods on `*model` work if you return `m` (the pointer); methods on `model` (value) work if you return the value. Either is idiomatic. Pointers are easier when you have long-lived state.

## The View struct

In v2, `View()` returns `tea.View`, not `string`. The struct carries the rendered content plus terminal-level flags:

```go
type View struct {
    Content                   string             // the rendered string (use SetContent or NewView)
    AltScreen                 bool               // enter alt screen
    MouseMode                 MouseMode          // None | CellMotion | AllMotion
    ReportFocus               bool               // get FocusMsg / BlurMsg
    DisableBracketedPasteMode bool               // most TUIs want false (default)
    WindowTitle               string             // sets terminal title
    Cursor                    *Cursor            // position, shape, color, blink
    BackgroundColor           color.Color        // sets the *terminal's* bg color (rare)
    ForegroundColor           color.Color        // sets the *terminal's* fg color (rare)
    ProgressBar               *ProgressBar       // OSC 9;4 progress (terminal-native)
    KeyboardEnhancements      KeyboardEnhancements // Kitty protocol opt-in flags
    OnMouse                   func(MouseMsg) Cmd // intercept mouse based on content
}
```

The runtime reads this struct EVERY render. So you can change `AltScreen`, `MouseMode`, etc. by mutating model state — no commands needed.

**Common shape** (set fields once, set Content from your render):

```go
func (m *model) View() tea.View {
    body := lipgloss.JoinVertical(lipgloss.Left,
        m.header(),
        m.body(),
        m.footer(),
    )
    v := tea.NewView(body)
    v.AltScreen = true
    v.MouseMode = tea.MouseModeCellMotion
    return v
}
```

## Messages

`tea.Msg` is `any` (an empty interface). Match in `Update` with a type switch:

```go
func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.WindowSizeMsg:        // terminal resized
        m.width, m.height = msg.Width, msg.Height
        m.relayout()
        return m, nil

    case tea.KeyPressMsg:           // key pressed
        return m.handleKey(msg)

    case tea.MouseWheelMsg, tea.MouseClickMsg, tea.MouseReleaseMsg, tea.MouseMotionMsg:
        // forward to viewport if you have one
        var cmd tea.Cmd
        m.viewport, cmd = m.viewport.Update(msg)
        return m, cmd

    case myCustomMsg:               // your own types
        m.data = msg.payload
        return m, nil
    }
    return m, nil
}
```

**Key gotchas**:
- `tea.KeyMsg` and `tea.MouseMsg` are **interfaces** in v2. Always match the concrete types (`KeyPressMsg`, `MouseClickMsg`, etc.).
- `msg.String()` on `KeyPressMsg` returns the keystroke including modifiers — `"ctrl+c"`, `"shift+enter"`, `"alt+x"`, `"esc"`, `"pgup"`, etc.
- Bare letter keys come as the letter: `"a"`, not `"KeyA"`.

## Commands

A `tea.Cmd` is `func() tea.Msg`. The runtime calls it asynchronously and feeds the result back to `Update`. Use commands for I/O:

```go
func loadData() tea.Cmd {
    return func() tea.Msg {
        data, err := fetchFromAPI()
        return dataLoadedMsg{data: data, err: err}
    }
}

// Trigger from Update:
return m, loadData()

// Batch:
return m, tea.Batch(loadData(), m.spinner.Tick)

// Sequence (one after another):
return m, tea.Sequence(loadData(), saveData())
```

Common commands shipped with bubbletea:
- `tea.Quit` — exit the program
- `tea.Batch(cmd1, cmd2, ...)` — run concurrently
- `tea.Sequence(cmd1, cmd2, ...)` — run in order (v2 renamed from v1's `Sequentially`)
- `tea.Tick(d, fn)` — schedule a msg after duration `d`
- `tea.Println(args...)` — print above the alt-screen (rarely useful)
- `tea.SetWindowTitle(s)` — *use `v.WindowTitle = s` in View() instead in v2*

## Async patterns

### Tick-based animation

For spinners and progress, return a tick command that re-schedules itself:

```go
type tickMsg time.Time

func tick() tea.Cmd {
    return tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
        return tickMsg(t)
    })
}

func (m model) Init() tea.Cmd { return tick() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg.(type) {
    case tickMsg:
        m.frame++
        return m, tick()  // reschedule
    }
    return m, nil
}
```

### Streaming from a goroutine (the important one)

When you have a blocking iterator (an LLM stream, a tail -f, an HTTP SSE), you CAN'T loop on it from a tea.Cmd because each Cmd is called once. The pattern is: kick off a goroutine that uses `(*tea.Program).Send(msg)` to feed the event loop directly.

```go
func (m *model) streamCmd(prompt string) tea.Cmd {
    return func() tea.Msg {
        go func() {
            stream := openStream(prompt)
            for stream.Next() {
                chunk := stream.Current()
                m.prog.Send(streamDeltaMsg{text: chunk})  // ← pumps directly into the event loop
            }
            m.prog.Send(streamDoneMsg{err: stream.Err()})
        }()
        return nil   // initial cmd returns nil; messages arrive asynchronously
    }
}
```

The `*tea.Program` must be captured before the goroutine starts. Standard idiom:

```go
func runApp() error {
    m := newModel(...)
    p := tea.NewProgram(m)
    m.prog = p     // capture before Run
    _, err := p.Run()
    return err
}
```

**Why this works**: Bubble Tea's event loop is single-threaded. `prog.Send` enqueues a message; `Update` processes it on the main goroutine. Any state mutation in `Update` is automatically serialized — no mutex needed on the model.

**Why a recursive `tea.Cmd` doesn't work**: SDK iterators like `openai-go`'s `*Stream` aren't re-entrable across multiple Cmd invocations. The goroutine + Send pattern keeps the iterator alive in one place.

### Multiple in-flight requests (concurrent submits)

For chat-style apps where the user can fire multiple prompts without waiting:

```go
type model struct {
    nextTurnID int64        // monotonic counter
    inflight   int          // count of pending requests
    transcript []turn
}

type turn struct {
    role   string
    text   string
    turnID int64            // links user turn to assistant turn
}

type deltaMsg struct{ turnID int64; text string }
type doneMsg  struct{ turnID int64; err error }

func (m *model) submit(prompt string) tea.Cmd {
    m.nextTurnID++
    id := m.nextTurnID
    m.transcript = append(m.transcript,
        turn{role: "user", text: prompt, turnID: id},
        turn{role: "assistant", text: "", turnID: id},
    )
    m.inflight++
    return func() tea.Msg {
        go func() {
            for ev := range stream(prompt) {
                m.prog.Send(deltaMsg{turnID: id, text: ev})
            }
            m.prog.Send(doneMsg{turnID: id})
        }()
        return nil
    }
}

// Update routes deltas to the matching assistant turn by turnID:
case deltaMsg:
    for i := range m.transcript {
        t := &m.transcript[i]
        if t.turnID == msg.turnID && t.role == "assistant" {
            t.text += msg.text
            break
        }
    }
```

This pattern unlocks "type while waiting" — see `patterns.md` for the full recipe.

## State serialization (when concurrency bites)

If goroutines mutate shared model state directly, you race. Two correct fixes:

**(a) Snapshot, send results, mutate in Update.** The goroutine reads model state once, sends results back, Update applies them on the main goroutine.

**(b) Pass mutation as messages.** The goroutine never touches the model; it only sends messages describing what changed.

Bubble Tea's event loop guarantees serialization within Update. **Treat Update as the only place model state changes happen.**

## Window resize

Always handle `tea.WindowSizeMsg`. It fires once at startup and again on every resize:

```go
case tea.WindowSizeMsg:
    m.width, m.height = msg.Width, msg.Height
    m.relayout()
    return m, nil
```

Inside `relayout`, recompute the sizes of every sub-component (viewport, textarea, panes). Don't hardcode 80x24.

## Keyboard enhancements (Kitty protocol)

For terminals that speak the Kitty keyboard protocol (Ghostty, Kitty, WezTerm, foot, recent iTerm2), Bubble Tea v2 negotiates extended key reporting automatically. This is what lets you distinguish `shift+enter` from `enter`, `ctrl+i` from `tab`, etc.

You opt in by listening for `tea.KeyboardEnhancementsMsg` and adjusting behavior:

```go
case tea.KeyboardEnhancementsMsg:
    m.keyboardEnhanced = msg.SupportsKeyDisambiguation()
    return m, nil

case tea.KeyPressMsg:
    if msg.String() == "shift+enter" {
        // works on supported terminals; on others, falls through to "enter"
        m.input.InsertNewline()
        return m, nil
    }
```

For terminals that DON'T support it (macOS Terminal.app, stock iTerm2), `shift+enter` arrives as plain `enter`. Always provide a fallback (e.g., `ctrl+j`).

To request additional enhancements (key repeat reporting, alternate keys), set fields on `tea.View.KeyboardEnhancements`:

```go
func (m model) View() tea.View {
    v := tea.NewView(m.body())
    v.KeyboardEnhancements.ReportEventTypes = true   // key repeat + release events
    return v
}
```

## Init() patterns

Common Init returns:
- `nil` — nothing to do at startup
- `m.spinner.Tick` — start a spinner immediately
- `tea.Batch(textarea.Blink, tea.RequestBackgroundColor)` — multiple at once
- `tea.RequestBackgroundColor` — get a `tea.BackgroundColorMsg` so you can set up adaptive styles before first render

For adaptive theming, request the bg color in Init:

```go
func (m model) Init() tea.Cmd {
    return tea.RequestBackgroundColor
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    switch msg := msg.(type) {
    case tea.BackgroundColorMsg:
        m.styles = newStyles(msg.IsDark())
        return m, nil
    }
}
```

## Composition

Bubble Tea has no formal "component" abstraction — components ARE models. Compose by embedding a `Model` field, calling its `Update`, and rendering its `View`:

```go
type model struct {
    input    textarea.Model
    viewport viewport.Model
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
    var cmds []tea.Cmd
    var cmd tea.Cmd

    m.input, cmd = m.input.Update(msg)
    cmds = append(cmds, cmd)

    m.viewport, cmd = m.viewport.Update(msg)
    cmds = append(cmds, cmd)

    return m, tea.Batch(cmds...)
}

func (m *model) View() tea.View {
    return tea.NewView(lipgloss.JoinVertical(lipgloss.Left,
        m.viewport.View(),
        m.input.View(),
    ))
}
```

**Focus management**: when multiple input components exist, only one should receive most key events at a time. Track focus on the parent model, route keys conditionally, and Focus/Blur the components in response to tab / clicks.

## Cleanup and shutdown

Return `tea.Quit` from Update to exit gracefully. The program writes back to the inline screen (alt screen exits automatically), restores the cursor, and returns from `p.Run()`.

If you spawned goroutines, they outlive `tea.Quit`. `prog.Send` after Quit is a no-op (documented behavior), so streaming goroutines don't panic — but they keep running until the underlying iterator exits. For long-running goroutines, also pass a context that gets cancelled on Quit.

## See also

- `components.md` — how to wire up textarea/viewport/list/table inside this architecture
- `patterns.md` — complete code recipes for chat, palette, dashboard, form, etc.
- `gotchas.md` — the bugs that bite first-time v2 users
