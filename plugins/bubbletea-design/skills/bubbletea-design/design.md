# Design: principles for sexy TUIs

A terminal isn't a small browser. The constraints are different: monospace grid, 256-or-fewer-colors, no images (mostly), keyboard-first input, instant feedback. The TUIs that feel amazing aren't the ones that fight those constraints; they're the ones that use them as a feature.

This file is the *why*. The other files are the *how*.

## The five principles

### 1. One accent color. Choose it deliberately.

Pick a single saturated color and use it for the things that matter: the active selection, the brand mark, the cursor, the "now" indicator. Every other element is grey, dim, or default.

```go
var (
    colorAccent   = lipgloss.Color("82")  // bright cyan-green
    colorMuted    = lipgloss.Color("244") // medium grey for body
    colorDim      = lipgloss.Color("242") // dim grey for hints
    colorBorder   = lipgloss.Color("242")
)
```

The accent does double duty as a focus indicator. When you have multiple panes, the focused one borders in the accent; the others border in `colorBorder` (a dim grey). The eye knows where to look without a second cue.

When you need two accents (e.g., a warn and an error state), pick the SECOND accent from a different hue family so they're never confused. Amber (`214`) + red (`203`) work for warning + danger. Accent green + amber + red gives you three semantic states. That's the max.

### 2. Vertical and horizontal axes, never diagonals.

Terminals can't draw diagonals well. Everything aligns to either a vertical or horizontal axis. Use this. A status footer's left edge aligns with the input's left edge aligns with the viewport's left edge. The right edge of a hint aligns with the right edge of the terminal. Three visible alignment lines: left margin, center axis (for centered empty states), right margin.

Lip Gloss's `JoinVertical(Left, ...)` and `JoinHorizontal(Top, ...)` are your friends. `Place` snaps content to a corner or center. Don't be cute with alignment positions like `0.7`: pick `Left`, `Center`, or `Right`.

### 3. Borders group concepts. Whitespace separates them.

A rounded border around the input box says "this is the input." Bordering everything weakens the signal: borders are heavy. Box the things the user interacts with. Leave the rest open.

Whitespace is free in a terminal. A blank line between sections feels expensive on paper but is the cheapest way to slow the eye in a TUI. Don't pack content together; give it room.

```
┌──────────────────────────────────────┐
│ Header text                          │
│                                      │   ← blank row gives the eye breathing room
│ Body content lives here.             │
└──────────────────────────────────────┘
```

### 4. Status footers earn their height.

Two rows max. Four rows is a wall of text. Every footer row should answer a question the user has:

- **Row 1**: where am I and what's happening? (model, context %, in-flight state)
- **Row 2**: last-turn deltas, cost, or whatever's tracking-but-secondary

Move the keybind hint to the right side of row 1 instead of its own row. That's free real estate. Replace the hint with a `⏳ working…` indicator when something's in flight; the user doesn't need the hints during a stream, they need to know it's running.

```
[████░░░░░░] 23%  grok-4.3  4,521↑ 1,830↓                    ↵ send · ⇧↵ newline · /exit
last: +412↑ +180↓ $0.0040 · session $0.043
```

### 5. The empty state is the first impression. Don't waste it.

When the user launches a fresh TUI or runs `/clear`, the viewport is empty. Default behavior is to show nothing. That's a missed opportunity. Use the space for:

- Centered ASCII / Braille banner of the brand mark
- One-line tagline below it
- The most important keybind ("type to start", "press / for commands")

```
                  ⠀⠀⠰⠰⠰⠰⠰⠰⠀⠀⠀⠀⠀⠀⠀⠆⠀⠀⠀⠀
                  ⠀⠠⠠⠈⠈⠈⠈⠈⠈⠀⠀⠀⠀⠀⠄⠅⠁⠀⠀⠀
                  ⡁⠁⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⡁⡁⡁⠀⠀⠀⠀
                  ⡂⠂⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠂⡂⡂⡂⠀⠀⠀⠀
                  ⠆⠆⠀⠀⠀⠀⠀⠀⠀⠀⠰⠀⠀⠀⠀⠆⠆⠆⠀⠀⠀
                  ⡅⡅⠀⠀⠀⠀⠀⠀⠀⠀⢠⠈⠀⠀⠀⠀⡅⡅⡅⠀⠀⠀
                  
                       subscription chat with xAI Grok
```

Use `chafa` to convert a logo PNG to Braille. The resulting density depends on the source: a high-contrast monochrome logo works best.

## Color palette specifics

### Dark-mode TUIs (the common case)

| Role | 256-color | Hex | Notes |
|---|---|---|---|
| Background of input/panels | `236`, `237`, `238`, `240` | `#3a3a3a`–`#5a5a5a` | 240 reads as "chalky grey" |
| Border (unfocused) | `242` | `#6c6c6c` | dim, present but quiet |
| Border (focused) | accent | (varies) | green, blue, amber depending on brand |
| Body text | `252` | `#d0d0d0` | high contrast on dark bg |
| Dim text (hints, captions) | `244` | `#808080` | one step down from body |
| Italics / muted | `242` | `#6c6c6c` | for less-important info |
| Accent (single) | pick one: `82`, `39`, `170`, `214` | (varies) | DO use this for the brand element |
| Error | `203` | `#ff5f5f` | bright red |
| Warn | `214` | `#ffaf00` | amber |
| Success | `82` | `#5fff5f` | bright green (if your accent isn't green) |

### Light-mode TUIs

Light mode TUIs are rarer but the principle is the same. Background should be near-white but not pure white (`255` is too bright; use `252` or `250`). Foreground darkens proportionally.

Use `lipgloss.LightDark(isDark)` to pick at runtime. Don't hardcode for one mode.

### Saturated accent picks by vibe

| Vibe | Color | Hex |
|---|---|---|
| Energetic / brand "go" | `82` cyan-green | `#5fff5f` |
| Calm / trustworthy | `39` blue | `#00afff` |
| Premium / creative | `170` purple | `#d75fd7` |
| Warm / handcrafted | `214` amber | `#ffaf00` |
| Sharp / urgent | `203` coral red | `#ff5f5f` |

Pick the one that matches the *feel* of what you're building, not what looks best in isolation.

## Spacing

- **Inside borders**: `Padding(0, 1)` for compact panes, `Padding(1, 2)` for forms and dialogs.
- **Between sections**: one blank row. Two if you want a chapter break.
- **Footer rows**: tight. No padding. The footer is dense by design.
- **Banner**: at least 4 rows above and below in the viewport.

If you find yourself wishing for sub-cell spacing, consider whether a border or background change would communicate the same thing better.

## Typography (in a monospace world)

- **Bold** = importance. Use sparingly. Bold + accent = the most important thing on screen.
- **Italic** = supplementary info. Hints, captions, placeholder text.
- **Faint** (dim) = inactive, secondary. Use for keybind hints, timestamps, IDs.
- **Underline** = mostly avoid in TUIs; reserve for links or active tabs.
- **Strikethrough** = "removed" / "completed". Common in todo lists.

```go
styleBody  := lipgloss.NewStyle().Foreground(lipgloss.Color("252"))
styleBold  := styleBody.Bold(true)
styleHint  := lipgloss.NewStyle().Foreground(lipgloss.Color("242")).Faint(true).Italic(true)
styleTitle := styleBold.Foreground(lipgloss.Color("82"))
```

## The "where am I" question

At every moment, the user should be able to answer three questions in under a second:

1. **What am I looking at?** (Banner / current panel / breadcrumbs)
2. **What can I do?** (Keybinds in footer or `?` for help)
3. **Is something happening I should wait on?** (Spinner, working indicator, progress bar)

If any of those takes more than a second to find, the layout needs to change.

## Live feedback for slow operations

Anything taking longer than ~500ms needs visible motion. Options in order of preference:

1. **Stream the events** (LLM chat, search persona events). If you have intermediate state, show it.
2. **Progress bar** with percentage if you know the total work.
3. **Spinner** with a status line ("Generating image…") if you don't know progress.
4. **Working indicator in footer** for background tasks the user submitted (count of in-flight requests).

Never just freeze. A 5-second pause with no visible change is a bug.

## Mouse vs keyboard

Default to keyboard-first. Bind mouse wheel to viewport scroll because it's expected, and bind mouse click to focus (in multi-pane TUIs) because it's cheap. Beyond that, don't make mouse the primary interaction; keyboard is faster and works over SSH.

Document the keyboard surface in a `/help` command and (compactly) in the footer.

## The single best test: blink test

Look at your TUI for 1 second. Look away. Describe what you saw.

If you can describe:
- The shape of the layout (header / body / footer / panels)
- The accent color and what it marks
- Whether anything is in progress

…you've designed well. If your description is "a wall of text", you need more whitespace, fewer columns, or a single focal point.

## Anti-patterns to avoid

- **Multiple accent colors** competing for attention.
- **Bordering everything** until borders mean nothing.
- **Dense footers** that take up half the screen.
- **No empty-state design**: just a blank viewport.
- **Placeholder text as keybind reference** (it gets in the way of typing).
- **Status text in plain default color** that's indistinguishable from the body.
- **Truecolor hex on terminals that don't support it** without trusting the downsampler.
- **Centered alignment for paragraphs**: bad in TUIs. Left-align body text; center only short titles and banners.
- **Animations that don't add information**: spinners belong on operations, not on idle UI.
- **The cursor moving for no reason** between renders. Lock it where you want it.

## A worked example: grok-chat's final design

The grok-chat TUI uses every principle here:

- **One accent** (color 82, cyan-green) for the brand mark, the input's left-edge bar, the working indicator, and the slash-palette selection marker.
- **Bordered input** (rounded border, padding 0,1) with a filled grey background. Single focal point.
- **Two-row footer**: row 1 has the status bar (left) and hint/working indicator (right); row 2 has last-turn deltas. Free real estate; nothing wasted.
- **Empty-state banner**: Braille rendering of the xAI Grok mark, centered in the viewport, with a single-line tagline below.
- **Slash palette** with `/help` as the first entry (harmless default).
- **Live streaming** for /search and /image: every persona event scrolls in live; the user sees motion within a second of submitting.
- **Working indicator** in the footer when `inflight > 0`, showing a count if multiple are in flight.
- **Mouse wheel** scrolls the viewport. Ctrl+U scrolls a half-page up. Ctrl+C and `/exit` both quit.

None of these are decorative. Each one answers a specific UX question. That's the whole game.

## See also

- `styling.md`: how to actually achieve these looks in Lip Gloss
- `patterns.md`: the layouts that bring these principles together
