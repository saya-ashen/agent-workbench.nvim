# π.nvim — Visual Design Specification

> **Quiet hierarchy** — let semantic color and whitespace lead; structural
> marks stay subtle and appear only when they clarify a real boundary.
>
> A chat UI is read, not scanned like code. The design goal is the same as
> good book typography: the reader should never notice the design, only the
> content. Differentiation comes from color temperature and rhythm, not from
> box-drawing characters or structural glyphs.

---

## 0 · Design Principles

| # | Principle | What it means in practice |
|---|-----------|--------------------------|
| 1 | **Semantic color over chrome** | Role, interaction, code, and state colors have distinct jobs. The assistant rail groups text segments but never carries a role hue. |
| 2 | **Whitespace before lines** | Turn boundaries remain blank space. A single muted rail is reserved for assistant text segments split by tool/thinking blocks. |
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
│ section     │ Normal.fg        │ Agent Output / Activity (bold)      │
│ thinking    │ Special.fg       │ Thinking header + body (italic)     │
│ error       │ DiagnosticError  │ Error rail + error text             │
├─────────────┼──────────────────┼─────────────────────────────────────┤
│ muted       │ Comment.fg       │ Timestamps, rails, tool body        │
│ body        │ Normal.fg        │ Agent prose (the default voice)     │
└─────────────┴──────────────────┴─────────────────────────────────────┘
```

### 1.2 The Rule

**Color has one meaning per semantic family.** The user's message body is
colored with `Title.fg` — the same hue as their icon — and indented two columns,
so indent + color together mark it as quoted input. The agent icon keeps
`Function.fg`, while the `Agent Output` / `Agent Activity` section text uses
`Normal.fg` bold; structure no longer competes with links or headings.

Agent prose stays `Normal.fg` and receives only a `Comment.fg` segment rail.
Links use the colorscheme's `Underlined` / `DiagnosticInfo` hue plus an
underline, inline code uses `String.fg` over `CursorLine.bg`, lower headings use
body color plus weight, and list markers recede to `Delimiter` / `Comment`.
Tool bodies remain muted; thinking keeps `Special.fg` italic.

### 1.3 Role Icons (colored foreground, no fill)

Each message type leads with a Nerd Font icon tinted in its role hue — a
small colored marker, never a filled pill. The icon + timestamp sit on one
line; the message body follows after a breathing blank line.

- **User icon**: `fg = Title.fg`, bold
- **Agent icon**: `fg = Function.fg`, bold
- **Agent section label**: `fg = Normal.fg`, bold
- **Error icon**: `fg = DiagnosticError.fg`, bold

Role is carried by the icon color and (for the user) the body text color. The
agent section label is intentionally neutral; only inline code and tool bodies
may use the existing subtle `CursorLine.bg` surface.

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
 [icon] Agent Output  Jul 24 2026, 21:41

│ I'll look at the auth module now. Let me read the current
│ implementation first.
```

- Icon line: role-colored icon (`Function.fg`) + neutral bold section label + muted timestamp
- Blank line
- Body text: **Normal.fg** with a `Comment.fg` left rail grouping this text segment
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
- This is the only **high-emphasis** structural element; assistant segment rails remain thin and muted
- Justified: errors must break the visual flow; color alone isn't enough
  during fast scrolling
- Long lines are hard-wrapped to the history window width so every screen
  line is a buffer line carrying the rail; a soft wrap would leave
  continuation lines rail-less at column 0 and break the block apart

---

## 6 · Compaction

```
────── [icon] compacted · 142k tokens ──────
```

- Centered, dash-delimited, Comment.fg italic
- The only centered element — signals "interstitial event, not a message"

---

## 7 · Status Spinner (transcript-attached virtual lines)

```
  ────────────────────────────────
[spinner]  verb… 27s · [thinking icon]
```

- Rendered as `virt_lines` immediately below the last real transcript row, so
  busy state and pending queue remain attached to the latest output.
- A short muted divider separates status from transcript content; rows are
  left-aligned and padded to the current History text width.
- Spinner + verb: `PiBusy` (Function.fg bold); time: `PiBusyTime` (Comment.fg);
  thinking suffix: `PiThinking` (Special.fg italic).
- Pending steer/follow-up rows share the same virtual-line block below the busy
  row, with muted labels and previews.
- The extmark is removed automatically when there is no active status or pending
  queue, and on `chat:clear()` (session switch).

---

## 8 · Highlight Groups

```
┌─────────────────────────┬───────────────────────────────────────────┐
│ Group                   │ Definition                                │
├─────────────────────────┼───────────────────────────────────────────┤
│ PiUserMessageLabel      │ fg=Title.fg bold (user role icon)         │
│ PiUserBody              │ fg=Title.fg (indented user body text)     │
│ PiAgentResponseLabel    │ fg=Function.fg bold (agent role icon)     │
│ PiAgentSectionLabel     │ fg=Normal.fg bold (Output / Activity)     │
│ PiAssistantBlockBorder  │ fg=Comment.fg (assistant segment rail)    │
│ PiSystemErrorIcon       │ fg=DiagnosticError.fg bold (error icon)   │
│ PiToolHeader            │ fg=Function.fg bold                       │
│ PiToolBorder            │ fg=Comment.fg (fold glyph ▾/▸)           │
│ PiToolBody              │ bg=CursorLine.bg (optional, subtle)       │
│ PiToolCall              │ fg=Normal.fg (input text)                 │
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

Markdown content uses a separate semantic palette:

- H1/H2: `Title.fg` bold; H3–H6: inherited body foreground, bold
- Links: `Underlined.fg` or `DiagnosticInfo.fg`, always underlined
- Inline code: `String.fg` over `CursorLine.bg`
- List markers: `Delimiter.fg` or `Comment.fg`
- Checked tasks: `DiagnosticOk.fg`; unchecked tasks: `Comment.fg`

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
│        │ Agent prose      │ Normal.fg + muted segment rail            │
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

│ The active window is 39845891 — a WezTerm running nvim. I've captured
│ the screenshot to /tmp/screenshot.png.  · 27s


 [icon]  Jul 24 2026, 21:43

  Great, now analyze the screenshot and tell me what you see.

────── [icon] compacted · 142k tokens ──────

 [icon]  Jul 24 2026, 21:44

│ The screenshot shows a Neovim instance with the pi chat panel open on
│ the right side.  · 3s
```

**Color annotations** (not visible in plain text):
- User body lines ("I need you to find...", "Great, now analyze..."): **Title.fg + 2-space indent**
- Agent prose ("The active window is...", "The screenshot shows..."): **Normal.fg + Comment.fg rail**
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
| Agent prose stays neutral | `Normal.fg` remains the primary reading voice; the muted rail groups segments without turning prose into colored chrome. |
| Whitespace turn gaps, not lines | A drawn line is an object the eye must process. An extra blank line is processed pre-attentively as "pause." It's the difference between a wall and a doorway. |
| Tool output italic, not colored | Italic is the lightest possible differentiation. It shifts texture without adding a new color to the palette. Regular = command; italic = echo. |
| Thinking in Special.fg | A distinct hue (pink/orange/purple) immediately signals "non-standard content." Combined with italic, it says "internal, skippable" without any structural marker. |
| Error rail is the loud exception | Assistant rails are muted grouping aids. Errors alone use a saturated, heavy rail because they must be unmissable during fast scrolling. |
| Fold glyph muted, not accent | `▾`/`▸` are UI controls, not content. They should recede. The tool name in bold accent does the identification work. |
| Inline tools fade on completion | Focus follows action. A screen full of accent-colored completed reads creates "shouting" where nothing stands out. |
