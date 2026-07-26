# Styling: Lip Gloss v2

Lip Gloss is to TUIs what CSS is to web. It composes immutable Style values, renders them to ANSI-styled strings, and provides layout primitives (Join, Place) that compose those rendered strings into rich layouts. This file is the working reference.

## The Style value

A `lipgloss.Style` is an immutable value type. Methods return new values; you chain them:

```go
style := lipgloss.NewStyle().
    Bold(true).
    Foreground(lipgloss.Color("#FAFAFA")).
    Background(lipgloss.Color("#7D56F4")).
    Padding(1, 2).            // vertical, horizontal
    Border(lipgloss.RoundedBorder()).
    BorderForeground(lipgloss.Color("#874BFD"))
```

To use it, call `Render(content)`:

```go
fmt.Println(style.Render("Hello, World!"))
```

Because styles are values, you copy by assignment and tweak:

```go
warning := style.Background(lipgloss.Color("#FF5733"))
// `style` is unchanged.
```

**This is the single most important pattern in Lip Gloss.** Define base styles once at package scope, derive variants by chaining.

## Colors

Lip Gloss accepts anything that implements `image/color.Color`. Convenience constructors:

```go
lipgloss.Color("82")          // 256-color palette index (0–255)
lipgloss.Color("#7D56F4")     // hex (truecolor; auto-downsamples on lesser terminals)
lipgloss.Color("9")           // ANSI 16-color (0–15)
lipgloss.NoColor{}            // unset / default
```

The renderer detects the terminal's color profile (TrueColor / 256 / 16 / NoColor) at startup via `colorprofile` and downsamples automatically. **You write hex; the user's terminal gets what it can handle.**

### The 256-color palette in practice

| Range | Use for |
|---|---|
| `0–7` | Standard ANSI (respects user theme): use these when you want theme parity |
| `8–15` | Bright ANSI (respects user theme) |
| `16–231` | The 6×6×6 RGB cube: most "saturated" colors live here |
| `232–255` | 24-step grayscale, dark → light |

**Greys for backgrounds**: 232 (near-black), 235, 236, 237, 238, 240, 244 (medium), 250, 255 (near-white). Hex `#3a3a3a` ≈ 237; `#5a5a5a` ≈ 240. 240 reads as "chalky grey" on most dark themes; 236 reads warmer and can look brown on warm terminal palettes.

**Brand accents**: pick ONE saturated 256-color or hex value (e.g. `82` for cyan-green, `39` for blue, `170` for purple, `214` for amber) and use it everywhere. More than one accent fragments the eye.

### Adaptive light/dark

Terminals can be either light or dark. Use `lipgloss.LightDark` to pick colors at runtime:

```go
func newStyles(isDark bool) styles {
    lightDark := lipgloss.LightDark(isDark)
    return styles{
        text: lipgloss.NewStyle().Foreground(lightDark(
            lipgloss.Color("#333333"), // for light terminals
            lipgloss.Color("#FAFAFA"), // for dark terminals
        )),
        accent: lipgloss.NewStyle().Foreground(lightDark(
            lipgloss.Color("#7D56F4"), // darker on light bg
            lipgloss.Color("#B794F4"), // lighter on dark bg
        )),
    }
}
```

Get the terminal's bg color in Bubble Tea by requesting it in `Init`:

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

For standalone Lip Gloss code (no Bubble Tea), use:

```go
isDark := lipgloss.HasDarkBackground(os.Stdin, os.Stdout)
```

### Gradients

`BorderForegroundBlend` and `WithColors(...)` blend across multiple stops:

```go
gradient := lipgloss.NewStyle().
    Border(lipgloss.RoundedBorder()).
    BorderForegroundBlend(
        lipgloss.Color("#00FA68"),
        lipgloss.Color("#9900FF"),
        lipgloss.Color("#ED5353"),
        lipgloss.Color("#9900FF"),
        lipgloss.Color("#00FA68"), // wrap back to start for seamless loop
    ).
    Padding(1, 2)
```

Gradient borders are striking but expensive. They recompute on every render. Use sparingly (one or two per screen).

## Borders

Built-in border styles:

```go
lipgloss.NormalBorder()      // single-line: ┌─┐ │ └─┘
lipgloss.RoundedBorder()     // rounded:    ╭─╮ │ ╰─╯
lipgloss.ThickBorder()       // thick:      ┏━┓ ┃ ┗━┛
lipgloss.DoubleBorder()      // double:     ╔═╗ ║ ╚═╝
lipgloss.BlockBorder()       // solid block: █
lipgloss.OuterHalfBlockBorder()
lipgloss.InnerHalfBlockBorder()
lipgloss.HiddenBorder()      // invisible (used for spacing)
```

Custom border characters with `lipgloss.Border{}`. Apply with `.Border(...)`:

```go
lipgloss.NewStyle().Border(lipgloss.RoundedBorder())                       // all 4 sides
lipgloss.NewStyle().Border(lipgloss.NormalBorder(), true, false, true, false) // top + bottom only
//                                                  ^^^^^^^^^^^^^^^^^^^^^^^^
//                                                  top, right, bottom, left
```

Color each side independently:

```go
lipgloss.NewStyle().
    Border(lipgloss.ThickBorder()).
    BorderTopForeground(lipgloss.Color("#FF0000")).
    BorderRightForeground(lipgloss.Color("#00FF00")).
    BorderBottomForeground(lipgloss.Color("#0000FF")).
    BorderLeftForeground(lipgloss.Color("#FFFF00"))
```

**Pattern (section headers)**: a bottom-only border feels lighter than a full box:

```go
section := lipgloss.NewStyle().
    Border(lipgloss.NormalBorder(), false, false, true, false). // bottom only
    BorderForeground(lipgloss.Color("99")).
    Padding(0, 1).
    Bold(true)
fmt.Println(section.Render("Configuration"))
```

## Padding, margins, dimensions

```go
.Padding(top, right, bottom, left int) Style
.Padding(vertical, horizontal int)   // 2 args
.Padding(all int)                    // 1 arg
.PaddingTop(n) / .PaddingRight(n) / etc.

.Margin(...)                          // same shape, but outside the border
.MarginTop(n) / etc.

.Width(n)          // fixed content width (excludes border + padding)
.Height(n)         // fixed content height
.MaxWidth(n)       // truncates if exceeded
.MaxHeight(n)
```

Width semantics: `Width(N)` sets the content area to N cells. With Padding(0,1) + RoundedBorder, the full rendered width is `N + 4` (2 for padding, 2 for border). To make a box exactly the terminal width, set `Width(termWidth - 4)`.

**Filling a box with a background color**: when you set both `Width` and `Background`, lines shorter than the width are padded with the bg color. This is how you make an empty container that visibly shows its bounds:

```go
panel := lipgloss.NewStyle().
    Width(40).
    Height(10).
    Background(lipgloss.Color("236")).
    Border(lipgloss.RoundedBorder()).
    BorderForeground(lipgloss.Color("242"))
fmt.Println(panel.Render("Header line\nLine 2"))
// Renders a 40-wide, 10-tall box. Lines 3-10 are filled with bg.
```

## Alignment

Horizontal alignment within a fixed-width style:

```go
lipgloss.NewStyle().Width(30).Align(lipgloss.Left)    // default
lipgloss.NewStyle().Width(30).Align(lipgloss.Center)
lipgloss.NewStyle().Width(30).Align(lipgloss.Right)
```

Vertical alignment requires `Height`:

```go
lipgloss.NewStyle().
    Width(30).
    Height(5).
    Align(lipgloss.Center, lipgloss.Center)   // horizontal, vertical
```

You can also pass `0.0–1.0` for custom positions:

```go
lipgloss.NewStyle().Align(0.75)   // 3/4 of the way to the right
```

## Layout primitives

### JoinVertical / JoinHorizontal

Compose rendered strings into multi-block layouts:

```go
top    := boxStyle.Render("Header")
middle := boxStyle.Render("Body content")
bottom := boxStyle.Render("Footer")

lipgloss.JoinVertical(lipgloss.Left, top, middle, bottom)
// align param: Left | Center | Right | 0.0-1.0
```

```go
left  := paneStyle.Render("Sidebar")
right := paneStyle.Render("Main")

lipgloss.JoinHorizontal(lipgloss.Top, left, right)
// align param: Top | Center | Bottom | 0.0-1.0
```

Blocks of different heights/widths are aligned per the position argument. Shorter blocks get padded with spaces.

### Place

`lipgloss.Place` puts content at a specific position within a `width × height` cell. Use for centered empty-states, banners, modals:

```go
banner := lipgloss.NewStyle().Foreground(lipgloss.Color("82")).Render(asciiArt)
centered := lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, banner)
```

`PlaceHorizontal(width, pos, content)` and `PlaceVertical(height, pos, content)` exist for single-axis placement.

### leftRight helper

A common need: left content + right content sharing one line, padded between. Lip Gloss doesn't ship this directly; write it once:

```go
func leftRight(width int, left, right string) string {
    gap := width - lipgloss.Width(left) - lipgloss.Width(right)
    if gap < 1 {
        gap = 1
    }
    return left + strings.Repeat(" ", gap) + right
}
```

Use `lipgloss.Width` (not `len`). It strips ANSI escapes so spacing is correct on styled strings.

## Composing styles by inheritance

`Style.Inherit(other)` copies any unset fields from `other`:

```go
base := lipgloss.NewStyle().Padding(0, 1).Foreground(lipgloss.Color("252"))
bold := lipgloss.NewStyle().Bold(true).Inherit(base)   // bold + base's padding + fg
```

Useful for theming: define a base style, derive variants with `.Inherit()`.

## Width-aware rendering

`lipgloss.Width(rendered) int` and `lipgloss.Height(rendered) int` measure the cell width/height of an already-rendered string, ignoring ANSI escape sequences. Use these for any custom layout math.

`lipgloss.Println(s)` is a wrapper around `fmt.Println` that downsamples colors to the terminal's profile. Use it for one-off prints from CLI helpers; in Bubble Tea, just return the string from `View()` and let the runtime handle output.

## Common style recipes

### Status badge

```go
badge := lipgloss.NewStyle().
    Padding(0, 1).
    Foreground(lipgloss.Color("0")).
    Background(lipgloss.Color("82")).
    Bold(true)
fmt.Println(badge.Render(" READY "))
```

### Card (header + body)

```go
header := lipgloss.NewStyle().
    Bold(true).
    Foreground(lipgloss.Color("82")).
    Padding(0, 1).
    Render("Notifications")
body := lipgloss.NewStyle().
    Padding(1, 2).
    Render("3 new messages\n2 mentions")
card := lipgloss.JoinVertical(lipgloss.Left, header, body)
boxed := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Render(card)
```

### Two-pane layout that fills terminal width

```go
left := lipgloss.NewStyle().Width(termWidth / 3).Border(lipgloss.NormalBorder()).Render(sidebar)
right := lipgloss.NewStyle().Width(termWidth - termWidth/3).Border(lipgloss.NormalBorder()).Render(main)
both := lipgloss.JoinHorizontal(lipgloss.Top, left, right)
```

### Progress bar (without bubbles/progress)

```go
func renderBar(pct float64, width int) string {
    filled := int(pct * float64(width))
    return "[" + strings.Repeat("█", filled) + strings.Repeat("░", width-filled) + "]"
}
// Then style:
styleAccent.Render(renderBar(0.42, 20))
```

### Banner / empty state

```go
const banner = `⠀⠀⠀⢀⣠⣶⣶⣦⣄⡀⠀⠀⠀
⠀⠀⣰⠟⠁⠀⠀⠀⠀⠈⠻⣆⠀⠀
…`
art := lipgloss.NewStyle().Foreground(lipgloss.Color("82")).Render(banner)
tag := lipgloss.NewStyle().Faint(true).Render("subscription chat with xAI Grok")
block := lipgloss.JoinVertical(lipgloss.Center, art, "", tag)
empty := lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, block)
```

Use `chafa` (CLI tool, `brew install chafa`) to convert a PNG logo into Braille glyphs:

```sh
chafa --symbols=braille --fg-only --colors=none --size=60x16 --preprocess=on \
      --format=symbols path/to/logo.png | sed '/^[⠀ ]*$/d'
```

Paste the output as a Go raw-string constant.

## Pitfalls

- **Don't measure with `len()`** on rendered styled strings. Use `lipgloss.Width(s)`. `len` counts ANSI escape bytes.
- **Don't expect Background to fill outside Width**. If your line is shorter than the style's Width, the bg fills to the Width but no further. To fill an entire box, set Width AND let lines be shorter; lipgloss pads with the bg color automatically.
- **Don't mutate a Style and expect the original to change**. Styles are values; assignment is a copy.
- **Don't use 24-bit hex on terminals that don't support TrueColor** without trusting the downsampler. Test in macOS Terminal.app (256-color only) and a TrueColor terminal (iTerm2, Ghostty, Kitty, Alacritty) at least.
- **Don't put gradients on every element**. They draw the eye; use them on the one or two things that matter most.

## See also

- `components.md`: every bubble has its own `Styles` struct; the lipgloss patterns here apply to all of them
- `design.md`: when to use which color, spacing, alignment for a polished result
- `patterns.md`: full layouts (chat, dashboard, picker) showing styling in context
