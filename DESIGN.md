# π.nvim — Visual Design Specification

> **Quiet hierarchy** — let color and whitespace speak; never draw a border
> that doesn't carry information.
>
> A chat UI is read, not scanned like code. The design goal is the same as
> good book typography: the reader should never notice the design, only the
> content. Differentiation comes from color temperature and rhythm, not from
> box-drawing characters or structural glyphs.

---

## 0 · Design Principles

| # | Principle | What it means in practice |
|---|-----------|--------------------------|
| 1 | **Color over chrome** | Role identification via foreground color on text, not via rails, borders, or structural symbols. Three role hues + one semantic hue. |
| 2 | **Whitespace over lines** | Turn boundaries are extra blank lines, never drawn rules. The eye reads a pause; it doesn't parse a glyph. |
| 3 | **One weight per role** | User = colored text. Agent = default text. Tool = muted + indented. Thinking = muted + italic + indented. No two roles share the same visual weight. |
| 4 | **Silence is the default** | Successful tools show no footer. Completed inline tools fade. The spinner lives only on the active line. |
| 5 | **Icons from one family** | Every glyph is a Nerd Font icon from `config.labels`. No emoji. No mixed sets. |

---

## 1 · Color System

All colors derive from the user's colorscheme via `nvim_get_hl`. No hardcoded hex.

### 1.1 The Palette — 3 Role Hues + 1 Semantic

```
┌─────────────┬──────────────────┬─────────────────────────────────────┐
│ Hue         │ Source           │ Applied to                          │
├─────────────┼──────────────────┼─────────────────────────────────────┤
│ user        │ Title.fg         │ User icon + indented user body text │
│ agent       │ Function.fg      │ Agent icon + tool header + spinner  │
│ thinking    │ Special.fg       │ Thinking header + body (italic)     │
│ error       │ DiagnosticError  │ Error rail + error text             │
├─────────────┼──────────────────┼─────────────────────────────────────┤
│ muted       │ Comment.fg       │ Timestamps, tool body, fold glyph   │
│ body        │ Normal.fg        │ Agent prose (the default voice)     │
└─────────────┴──────────────────┴─────────────────────────────────────┘
```

### 1.2 The Rule

**Color goes on text, not on structure.** The user's message body is colored
with `Title.fg` — the same hue as their icon — and indented two columns, so
indent + color together mark it as quoted input. The agent's prose stays
`Normal.fg`, flush-left — the absence of color and indent IS the signal that
this is the primary content.

Tool bodies use `Comment.fg` (muted) — they are subordinate actions, not
content to read. Thinking uses `Special.fg` italic — a distinct hue that says
"internal, skippable."

### 1.3 Role Icons (colored foreground, no fill)

Each message type leads with a Nerd Font icon tinted in its role hue — a
small colored marker, never a filled pill. The icon + timestamp sit on one
line; the message body follows after a breathing blank line.

- **User icon**: `fg = Title.fg`, bold
- **Agent icon**: `fg = Function.fg`, bold
- **Error icon**: `fg = DiagnosticError.fg`, bold

There are **no filled-background elements** in the history buffer. Role is
carried by the icon color and (for the user) the body text color. Everything
is foreground-only.

---

## 2 · Message Rendering

### 2.1 User Message

```
 [icon]  Jul 24 2026, 21:41

  I need you to refactor the auth module to use JWT tokens
  instead of session cookies.
```

- Icon line: role-colored icon (`Title.fg`) + timestamp (muted)
- Blank line (breathing room between header and body)
- Body text: **2-space indented** and tinted **Title.fg** (`PiUserBody`)
- Indent + color together mark this as quoted user input, subordinate to the
  agent's flush-left prose

### 2.2 Agent Response

```
 [icon]  Jul 24 2026, 21:41

I'll look at the auth module now. Let me read the current
implementation first.
```

- Icon line: role-colored icon (`Function.fg`) + timestamp (muted)
- Blank line
- Body text: **Normal.fg**, flush-left (the default — no decoration needed)
- Completion: `  · 7s` as virtual text on last prose line (muted)

### 2.3 Turn Separation

```
  [end of agent response]
                              ← blank line (normal spacing)
                              ← blank line (turn_separator adds this)
 [user icon]  Jul 24 2026, 21:43
```

When `turn_separator = true` (default), an **extra blank line** is inserted
between turns. No drawn line, no dots, no symbols. Just whitespace — the
typographic equivalent of a paragraph break vs a section break.

---

## 3 · Tool Blocks

### 3.1 Expanded

```
▾ [icon] bash
  xdotool search --name "nvim"

  39845891
  48234500
```

- Header: fold glyph (Comment.fg) + icon + name (Function.fg bold)
- The icon is **per-tool**: each tool name maps to its own Nerd Font glyph
  (e.g. `bash`→terminal, `read`→file, `edit`→pencil, `write`→save), with
  `config.labels.tool` as the fallback for unknown tools. The mapping lives
  in `tools.lua` (`TOOL_ICONS`, by codepoint) and is not user-configurable.
- Body: 2-space indent (virtual text) + Comment.fg
- Input: regular weight
- Output: **italic** (texture shift distinguishes result from command)
- Optional: subtle background from CursorLine.bg (when terminal is opaque)
- No footer on success. Error footer in DiagnosticError.fg.

### 3.2 Collapsed

```
▸ [icon] bash  xdotool search --name "nvim"…
```

### 3.3 Inline (completed)

```
  [icon] read  lua/pi/config.lua  (42 lines)
```

Icon + name fade to Comment.fg after completion. Only running tools stay
accent-colored.

---

## 4 · Thinking Blocks

```
[icon] Thought for 4s
  There are two windows with "nvim" in the name.
  The wezterm window is 39845891 (active).
```

- Header: flush-left, Special.fg italic
- Body: 2-space indent, Special.fg italic
- The distinct hue (pink/mauve/orange depending on colorscheme) + italic
  creates immediate "this is internal monologue" recognition

---

## 5 · Error Blocks

```
▌ [icon] RPC connection lost: process exited unexpectedly
▌ Stack trace:
▌   at Rpc._on_close (rpc.lua:142)
```

- `▌` left-half-block rail in DiagnosticError.fg
- This is the **only** structural element in the entire design
- Justified: errors must break the visual flow; color alone isn't enough
  during fast scrolling

---

## 6 · Compaction

```
────── [icon] compacted · 142k tokens ──────
```

- Centered, dash-delimited, Comment.fg italic
- The only centered element — signals "interstitial event, not a message"

---

## 7 · Status Spinner (pinned bottom overlay)

```
                  [spinner]  verb… 27s · [thinking icon]
```

- Rendered as a **borderless floating window pinned to the bottom row** of the
  history viewport (`relative="win"`, `row = win_height - height`). Because the
  position is viewport-relative, it stays glued to the bottom — directly above
  the prompt panel — regardless of where the history is scrolled.
- The spinner line is **horizontally centered** within the history width.
- Spinner + verb: `PiBusy` (Function.fg bold); time: `PiBusyTime` (Comment.fg);
  thinking suffix: `PiThinking` (Special.fg italic).
- The pending steer/follow-up queue is rendered in the same overlay, left-aligned
  above the spinner row.
- The overlay is torn down automatically when there is no active status and no
  pending queue, and on `chat:clear()` (session switch).

---

## 8 · Highlight Groups

```
┌─────────────────────────┬───────────────────────────────────────────┐
│ Group                   │ Definition                                │
├─────────────────────────┼───────────────────────────────────────────┤
│ PiUserMessageLabel      │ fg=Title.fg bold (user role icon)         │
│ PiUserBody              │ fg=Title.fg (indented user body text)     │
│ PiAgentResponseLabel    │ fg=Function.fg bold (agent role icon)     │
│ PiSystemErrorIcon       │ fg=DiagnosticError.fg bold (error icon)   │
│ PiToolHeader            │ fg=Function.fg bold                       │
│ PiToolBorder            │ fg=Comment.fg (fold glyph ▾/▸)           │
│ PiToolBody              │ bg=CursorLine.bg (optional, subtle)       │
│ PiToolCall              │ fg=Comment.fg (input text)                │
│ PiToolOutput            │ fg=Comment.fg italic (output text)        │
│ PiToolRunning           │ fg=Function.fg (spinner on header)        │
│ PiToolInlineDone        │ fg=Comment.fg (faded completed inline)    │
│ PiToolError             │ fg=DiagnosticError.fg italic              │
│ PiThinking              │ fg=Special.fg italic                      │
│ PiErrorRail             │ fg=DiagnosticError.fg (▌ on errors)      │
│ PiError                 │ fg=DiagnosticError.fg                     │
│ PiBusy                  │ fg=Function.fg bold (status spinner)      │
│ PiBusyTime              │ fg=Comment.fg (elapsed time)              │
│ PiMessageDateTime       │ fg=Comment.fg                             │
│ PiCompactionText        │ fg=Comment.fg italic                      │
└─────────────────────────┴───────────────────────────────────────────┘
```

---

## 9 · Visual Hierarchy

```
┌────────────────────────────────────────────────────────────────────┐
│ Weight │ Type             │ Treatment                                │
├────────┼──────────────────┼──────────────────────────────────────────┤
│ LOUD   │ Error            │ ▌ rail + error color                     │
│        │ Role icons       │ Colored fg icon per role (turn anchors)  │
│        │ Tool header      │ Function.fg bold + per-tool icon         │
│ MEDIUM │ User body        │ Title.fg colored text + 2-space indent   │
│        │ Agent prose      │ Normal.fg flush-left (default = primary) │
│ QUIET  │ Tool body        │ Comment.fg + indent                      │
│        │ Thinking         │ Special.fg italic + indent               │
│        │ Timestamps/meta  │ Comment.fg                               │
│ SILENT │ Completed inline │ Comment.fg (faded)                       │
│        │ Turn gap         │ Extra blank line (invisible)             │
└────────┴──────────────────┴──────────────────────────────────────────┘
```

---

## 10 · Complete Turn Mockup

```
π

 [icon]  Jul 24 2026, 21:41

  I need you to find the nvim window ID and take a screenshot.
  The window might be nested inside wezterm.


 [icon]  Jul 24 2026, 21:41

▾ [icon] bash
  xdotool search --name "nvim" 2>/dev/null

  39845891
  48234500

▸ [icon] bash  xdotool getwindowname 39845891

  [icon] read  lua/pi/config.lua
  [icon] read  lua/pi/init.lua

[icon] Thought for 4s
  There are two windows with "nvim" in the name: 48234500 and 39845891.
  The wezterm window is 39845891 (active).

▾ [icon] bash  ⠋
  maim -i 39845891 /tmp/screenshot.png

The active window is 39845891 — a WezTerm running nvim. I've captured
the screenshot to /tmp/screenshot.png.  · 27s


 [icon]  Jul 24 2026, 21:43

  Great, now analyze the screenshot and tell me what you see.

────── [icon] compacted · 142k tokens ──────

 [icon]  Jul 24 2026, 21:44

The screenshot shows a Neovim instance with the pi chat panel open on
the right side.  · 3s
```

**Color annotations** (not visible in plain text):
- User body lines ("I need you to find...", "Great, now analyze..."): **Title.fg + 2-space indent**
- Agent prose ("The active window is...", "The screenshot shows..."): **Normal.fg**
- Tool headers (`▾ [icon] bash`): **Function.fg bold**
- Tool body (`  xdotool...`, `  39845891`): **Comment.fg** (output italic)
- Thinking (`[icon] Thought...` + body): **Special.fg italic**
- Completed inline tools: **Comment.fg** (faded)
- Running tool spinner: **Function.fg**

---

## 11 · Config

```lua
---@field turn_separator? boolean  Extra blank line between turns (default: true)
```

---

## 12 · Design Rationale

| Decision | Why |
|----------|-----|
| User body colored + indented, not railed | A rail is a structural element that competes with content. Color on the text plus a 2-space indent marks quoted input quietly — it tints and nests the reading experience without adding visual objects to parse. |
| Agent prose uncolored | The default foreground IS the identity. "I am what you're here to read." Adding color would make it compete with user text. |
| Whitespace turn gaps, not lines | A drawn line is an object the eye must process. An extra blank line is processed pre-attentively as "pause." It's the difference between a wall and a doorway. |
| Tool output italic, not colored | Italic is the lightest possible differentiation. It shifts texture without adding a new color to the palette. Regular = command; italic = echo. |
| Thinking in Special.fg | A distinct hue (pink/orange/purple) immediately signals "non-standard content." Combined with italic, it says "internal, skippable" without any structural marker. |
| Error rail is the only exception | Errors must break the flow. A colored structural element is the minimum that achieves "unmissable during fast scroll" — color alone on text can be missed. |
| Fold glyph muted, not accent | `▾`/`▸` are UI controls, not content. They should recede. The tool name in bold accent does the identification work. |
| Inline tools fade on completion | Focus follows action. A screen full of accent-colored completed reads creates "shouting" where nothing stands out. |
