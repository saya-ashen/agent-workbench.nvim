# π.nvim — Visual Design Specification

> **Refined Terminal** — order through restraint, not emptiness.
>
> A terminal is dense by nature. The design goal is not to impose web-style
> whitespace onto 80 columns, but to build **visual hierarchy inside density**:
> fewer borders, one accent color, icons that agree with each other, and
> status that speaks only when something is happening.

---

## 0 · Design Principles

| # | Principle | What it means in practice |
|---|-----------|--------------------------|
| 1 | **De-frame, don't de-densify** | Remove box-drawing borders (`╭│├╰`). Replace with indentation + optional 1-col left rail. Content stays compact; chrome disappears. |
| 2 | **One accent, semantic states** | A single accent color (from the user's colorscheme `Function` group) marks the agent and active elements. State colors (green/red/amber) appear *only* on status glyphs — never decoratively. |
| 3 | **Icons from one family** | Every glyph is a Nerd Font monochrome icon from `config.labels`. No emoji. No mixed icon sets. One visual weight across the entire surface. |
| 4 | **Silence is the default** | Successful tool calls show no footer. The spinner lives only on the active line. Completed work recedes; only running and errored work draws the eye. |
| 5 | **Aligned axis, consistent rhythm** | Everything left-aligns to column 0. One blank line between turns; zero blank lines within a tool block; one blank line after a tool block before the next element. |

---

## 1 · Color Tokens

All colors derive from the user's colorscheme via `nvim_get_hl`. No hardcoded hex values. The token table below is the **single source of truth** — every highlight group in `highlights.lua` maps to exactly one token.

### 1.1 Semantic Roles

```
┌─────────────┬──────────────────────┬──────────────────────────────────────┐
│ Token       │ Source               │ Used for                             │
├─────────────┼──────────────────────┼──────────────────────────────────────┤
│ fg.strong   │ Normal.fg            │ User message body, tool name header  │
│ fg.body     │ Normal.fg            │ Agent response body                  │
│ fg.muted    │ Comment.fg           │ Timestamps, fold hints, left rail,   │
│             │                      │   meta info, tool input/output text  │
│ fg.accent   │ Function.fg          │ Agent label, spinner, focus, links   │
│ fg.warn     │ WarningMsg.fg        │ Attention, pending queue, notes      │
│ fg.error    │ DiagnosticError.fg   │ Error messages, failed tool status   │
│ bg.surface  │ Normal.bg            │ All panel backgrounds                │
│ bg.label    │ (per-role, see §1.2) │ User/agent label pill bg (retained)  │
└─────────────┴──────────────────────┴──────────────────────────────────────┘
```

### 1.2 Label Pill Colors (retained, refined)

The user/agent label pills (`PiUserMessageLabel`, `PiAgentResponseLabel`) are **kept** — they appear once per turn and provide strong role identification. But they are refined:

- **User pill**: `bg = Title.fg`, `fg = Normal.bg`, `bold = true` (unchanged)
- **Agent pill**: `bg = Function.fg`, `fg = Normal.bg`, `bold = true` (unchanged)
- **System/error pill**: `bg = DiagnosticError.fg`, `fg = Normal.bg`, `bold = true` (unchanged)

These are the *only* filled-background elements in the history buffer. Everything else is foreground-only.

### 1.3 State Colors (glyph-only, never decorative)

```
  running   → fg.accent     (spinner frame)
  success   → (invisible)   (no glyph, no color — silence)
  error     → fg.error      (✕ glyph + error text)
  attention → fg.warn       (amber indicator)
  thinking  → fg.muted      (italic, same as meta text)
```

---

## 2 · Icon System

### 2.1 Rule

Every icon is a Nerd Font glyph resolved from `config.labels.*`. The defaults already form a coherent set. The one violation in the current code is the **emoji `🧠`** used for the thinking block header — this must be replaced with `config.labels.thinking` (default `󰟶`).

Similarly, the status-line spinner prefix currently uses `config.labels.agent_response` (the robot icon) which is correct, but the thinking suffix uses a raw emoji in some code paths — all must go through `config.labels`.

### 2.2 Icon Registry

```
┌──────────────────┬───────────┬──────────────────────────────────┐
│ Semantic role    │ Config    │ Default glyph                    │
├──────────────────┼───────────┼──────────────────────────────────┤
│ user_message     │ labels.*  │                                  │
│ agent_response   │ labels.*  │ 󰚩                               │
│ tool             │ labels.*  │ 󰻂                               │
│ tool_success     │ labels.*  │                                  │
│ tool_failure     │ labels.*  │                                  │
│ thinking         │ labels.*  │ 󰟶                               │
│ compaction       │ labels.*  │ 󰏗                               │
│ attachment       │ labels.*  │                                  │
│ steer_message    │ labels.*  │ 󰾘                               │
│ follow_up_message│ labels.*  │ 󱇼                               │
│ system_error     │ labels.*  │ 󱚟                               │
│ error            │ labels.*  │ 󰘨 󱚟                           │
└──────────────────┴───────────┴──────────────────────────────────┘
```

### 2.3 Prohibited

- **No emoji** anywhere in rendered output. All `🧠`, `🤖`, `📎`, `⚡` etc. must be replaced by their `config.labels` equivalent.
- **No ad-hoc unicode symbols** (`●`, `◆`, `▸`, ``) outside the tool-block fold indicators defined in §4.

---

## 3 · Message Headers

### 3.1 User Message

**Before:**
```
 ██  13:02
 Some message text here
```
(filled pill with nerd-font icon + space + timestamp)

**After:** (unchanged — the pill works well at turn boundaries)
```
 ██  13:02
 Some message text here
```

The user pill is retained as-is. It provides a strong visual anchor at the top of each turn. The timestamp uses `PiMessageDateTime` (muted). Queue tags (`steer`/`follow_up`) use their respective muted-italic styles.

### 3.2 Agent Response

**Before:**
```
 ██  13:02

 Response text streams here…
```

**After:** (unchanged — same rationale)
```
 ██  13:02

 Response text streams here…
```

### 3.3 Vertical Rhythm Between Turns

```
  [agent response ends]
                          ← 1 blank line (turn separator)
  [user pill]  13:05
  [user message body]
                          ← 1 blank line (turn separator)
  [agent pill]  13:05
  [agent response body]
```

This is already the current behavior (`_begin_conversation_content` inserts a blank line). **No change needed.**

---

## 4 · Tool Blocks — The Primary Redesign

This is the highest-impact change. Tool blocks occupy the most screen area and currently use full box-drawing borders on every line.

### 4.1 Glyph System

**Before** (`tools.lua` GLYPHS):
```lua
M.GLYPHS = { TOP = "╭─ ", MID = "│  ", SEP = "├──── ", BOT = "╰─ " }
```

**After:**
```lua
M.GLYPHS = {
    RAIL  = "  ",    -- 2-space indent (replaces │  on body lines)
    SEP   = "  ",    -- blank indent (replaces ├──── separator)
    FOLD_OPEN  = "▾ ",  -- expanded indicator (replaces ╭─ on header)
    FOLD_CLOSE = "▸ ",  -- collapsed indicator
}
```

The left rail is **pure indentation** — no visible character. The tool block is identified by its header line (icon + tool name in `fg.strong`) and its indented body. No border characters at all.

> **Rationale**: In the screenshot, three consecutive tool blocks produce ~18 lines of `│`, `├`, `` characters. These are pure chrome — they carry zero information. Removing them recovers ~30% of vertical space and eliminates the "picket fence" effect.

### 4.2 Expanded Tool Block

**Before:**
```
╭─ 󰻂 bash
│  xdotool search --name "nvim" 2>/dev/null; echo "---wezterm---"; xdotool sear…
│
├────
│  …5 lines
│    39845891
╰─ ✓ completed
```
(8 lines: header + 1 input + blank-sep + 2 output + footer = 6 content + 2 chrome)

**After:**
```
▾ 󰻂 bash
  xdotool search --name "nvim" 2>/dev/null; echo "---wezterm---"; xdotool sear…

  …5 lines
    39845891
```
(5 lines: header + 1 input + blank-sep + 2 output = 5 content + 0 chrome)

Changes:
1. `╭─ ` → `▾ ` (fold indicator, 2 chars, same width)
2. `│  ` → `  ` (pure indent, no visible rail character)
3. `├──── ` → `  ` (separator becomes blank indent line; the blank line itself is the visual separator)
4. `╰─ ✓ completed` → **removed entirely** (success is silent, §4.4)
5. Header line: tool icon + tool name in `PiToolHeader` (fg.strong + bold). No border highlight on the fold indicator — it inherits `PiToolBorder` which becomes `fg.muted`.

### 4.3 Collapsed Tool Block

**Before:**
```
╭─  bash
│  xdotool search --name "nvim" 2>/dev/null; echo "---wezterm---"; xdotool sear…
│  …5 lines
│    39845891
╰─ ✓ completed
```

**After:**
```
▸ 󰻂 bash  xdotool search --name "nvim"…
```
Single line. The fold indicator `▸` + icon + tool name + truncated first input line as a muted preview. No footer. No border.

For inline tools (e.g. `read`), the format is:
```
  󰻂 read  lua/pi/config.lua
```
No fold indicator (inline tools can't expand). Just indent + icon + name + path.

### 4.4 Status Footer — Silence by Default

**Rule**: The `╰─ ✓ completed` / `╰─ ✕ error` footer line is **removed for successful tools**. Only errored tools show a footer.

**Before (success):**
```
╰─ ✓ completed
```

**After (success):**
```
(nothing — the block simply ends)
```

**Before (error):**
```
╰─ ✕ error: file not found
```

**After (error):**
```
  ✕ error: file not found
```
(Indented error line in `PiToolError`, no border prefix)

**Running state**: No footer line. The spinner appears in the **header line** as a virtual-text suffix:
```
▾ 󰻂 bash  
```
The braille spinner frame is appended as inline virtual text on the header row, highlighted in `PiBusy` (accent color). When the tool completes, the spinner virtual text is removed — no line added or removed, zero reflow.

### 4.5 Tool Block Spacing

```
  [previous element ends]
                          ← 0 blank lines before tool header
▾  bash
  command here
  output here
                          ← 1 blank line after tool block (breathing room)
  󰟶 Thought for 4s
  thinking content…
                          ← 1 blank line after thinking block
▾  edit
  file content…
                          ← 1 blank line after tool block
  Agent prose continues here…
```

Rule: **one blank line after every tool block and thinking block**. Zero blank lines before them (they follow naturally from the preceding content or blank line).

### 4.6 Fold Indicator Highlight

The `▸`/`▾` characters use `PiToolBorder` which is redefined from `fg = Comment.fg` to `fg = Comment.fg` (unchanged — muted is correct for fold indicators). They should not draw attention; the tool name in bold does that.

---

## 5 · Thinking Blocks

### 5.1 Header

**Before:**
```
🧠 Thought for 4s
```
(emoji icon, inconsistent with the nerd-font icon system)

**After:**
```
󰟶 Thought for 4s
```
(config.labels.thinking icon, `PiThinking` highlight = muted italic)

### 5.2 Body

**Before:**
```
🧠 Thought for 4s
There are two windows with "nvim" in the name: 48234500 and 39845891. The
wezterm window is 39845891 (active). Let me get the names of both to understand.
```
(No indentation — thinking body is flush-left, same column as agent prose)

**After:**
```
󰟶 Thought for 4s
  There are two windows with "nvim" in the name: 48234500 and 39845891. The
  wezterm window is 39845891 (active). Let me get the names of both to understand.
```
(2-space indent on body lines, matching tool block body indentation. This creates visual consistency: indented = subordinate content, flush-left = primary content.)

### 5.3 Collapsed Thinking

When thinking is collapsed (via toggle), show:
```
▸ 󰟶 Thought for 4s
```
Single line, same pattern as collapsed tool blocks.

---

## 6 · Status Line (In-History Spinner)

### 6.1 Alignment

**Before:**
```
              🤖 铺绢… for 27s · 🧠
```
(Centered via padding calculation in `_update_status_extmark`)

**After:**
```
  󰚩 铺绢… 27s · 󰟶
```
(Left-aligned with 2-space indent, matching all other content. The centering logic — `pad = math.floor((win_width - full_width) / 2)` — is removed.)

### 6.2 Format Changes

| Element | Before | After |
|---------|--------|-------|
| Spinner icon | `config.labels.agent_response` (🤖 emoji in some themes) | `config.labels.agent_response` (nerd font, verified) |
| Elapsed time | ` for 27s` | ` 27s` (drop "for", save 4 chars) |
| Thinking suffix | ` · 🧠` | ` · 󰟶` (nerd font) |
| Padding | Centered | Left-aligned, 2-space indent |

### 6.3 Highlight

- Spinner frame + model name: `PiBusy` (accent, bold)
- Elapsed time: `PiBusyTime` (muted)
- Thinking suffix: `PiThinking` (muted italic)

---

## 7 · Prompt Panel Title

### 7.1 Winbar Title

**Before:**
```
              󰫽󰫿󰫼󰫺󰫽󰬁
```
(Nerd-font PUA glyphs that render as stylized "PROMPT" with wide letter-spacing. Visually decorative but informationally empty — the user already knows this is the prompt because the cursor is in it.)

**After:**
```
 π › prompt
```
Or, more minimally, just keep the current nerd-font title but ensure it renders consistently. The key change is: **the title should not use letter-spaced PUA glyphs that look like a decorative banner**. Replace with a simple functional label.

Recommended config default change:
```lua
panels = {
    history = { title = "π" },           -- unchanged
    prompt = { title = "prompt" },       -- was PUA glyphs
    attachments = { title = "attached" }, -- was PUA glyphs
}
```

The winbar rendering (`set_winbar`) already centers the title with `%=`. With a short functional word, the centered title looks clean rather than like a decorative banner.

### 7.2 Attention State

When attention is pending, the prompt winbar title changes color (amber). This is already implemented and works well — **no change**.

---

## 8 · Highlight Group Changes

Summary of all highlight group modifications:

```
┌─────────────────────────────┬────────────────────────────────────────────┐
│ Group                       │ Change                                     │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolBorder                │ Unchanged (muted). Now used only on ▸/▾   │
│                             │ fold indicators, not on │/╭/╰ borders.    │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolHeader                │ Unchanged (accent + bold). Now the only   │
│                             │ strong element in a tool block.            │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolCall                  │ Unchanged (muted). Input text.             │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolOutput                │ Unchanged (muted). Output text.            │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolStatus                │ Repurposed: was the footer line highlight.│
│                             │ Now used only on error footer lines.       │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolCollapsed             │ Unchanged (muted italic). Fold preview.   │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiToolError                 │ Unchanged (error color italic).            │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiThinking                  │ Unchanged (muted italic).                  │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiBusy                      │ Unchanged (accent bold). Spinner line.    │
├─────────────────────────────┼────────────────────────────────────────────┤
│ PiBusyTime                  │ Unchanged (muted). Elapsed time.          │
├─────────────────────────────┼────────────────────────────────────────────┤
│ (new) PiToolRunning         │ fg = accent. Spinner glyph on tool header │
│                             │ virtual text while tool is in-flight.      │
├─────────────────────────────┼────────────────────────────────────────────┤
│ (new) PiToolSuccessGlyph    │ fg = DiagnosticOk. Optional: if we ever   │
│                             │ want to show ✓ on hover/focus. Default:   │
│                             │ not rendered (silence).                    │
└─────────────────────────────┴────────────────────────────────────────────┘
```

---

## 9 · Animation & Feedback

### 9.1 Spinner

- **Braille frames** (`⠋⠹⠸⠴⠧⠏`) retained — they are smooth and legible at 80ms.
- **Color**: spinner frame on the status line uses `PiBusy` (accent bold). Spinner frame on a tool header uses `PiToolRunning` (accent, not bold — lighter weight to not compete with the tool name).
- **Location**: the spinner appears as **inline virtual text** on the active line (status line or tool header), never on its own line.

### 9.2 State Transitions (zero reflow)

All state changes modify **existing extmarks** — no lines are inserted or deleted during a tool's lifecycle:

```
  Tool starts:
    1. Header line inserted: "▾ 󰻂 bash"
    2. Spinner virtual text appended to header: "▾  bash  ⠋"
    3. Body lines inserted below header as they arrive

  Tool completes (success):
    1. Spinner virtual text removed from header (extmark update)
    2. No footer line added
    → Net line change: 0 (only virtual text removed)

  Tool completes (error):
    1. Spinner virtual text removed from header
    2. Error line inserted below body: "  ✕ error: …"
    → Net line change: +1 (only on error — the exception that proves the rule)
```

### 9.3 Streaming Text

Agent response text streams via `_append_text` which appends to the last line. This is already smooth and requires no change. The cursor-follows-bottom behavior (`_scroll_to_bottom`) is correct.

### 9.4 Thinking Block Lifecycle

```
  Thinking starts:
    1. Thinking block inserted (header + empty body)
    2. Status line shows "· 󰟶" suffix

  Thinking streams:
    1. Delta text appended to thinking body lines

  Thinking ends:
    1. Status line suffix removed
    2. Thinking block remains visible (or auto-collapses per config)
```

---

## 10 · Complete Before/After — Full Turn Mockup

### Before (current, from screenshot)

```
π

╭─ 󰻂 bash
│  xdotool search --name "nvim" 2>/dev/null; echo "---wezterm---"; xdotool sear…
│
├────
│  …5 lines
│    39845891
╰─ ✓ completed

🧠 Thought for 4s
There are two windows with "nvim" in the name: 48234500 and 39845891. The
wezterm window is 39845891 (active). Let me get the names of both to understand.
48234500 might be a nested/inner nvim or the pi chat. Let me check window names
and geometry.

Actually 39845891 is the active wezterm window — that's likely the main nvim I'm
operating in (the pi chat). Let me screenshot it. But the pi chat might be a
side panel within it. Let me get window info first.

╰─ ✓ completed

╭─ 󰻂 bash
│  for w in 48234500 39845891; do echo "═══ $w ═══"; xdotool getwindowname "$w"…
│
├────
│  …9 lines
│      Map State: IsViewable
╰─ ✓ completed

🧠 Thinking…
The active viewable window is 39845891 — a WezTerm running nvim (the one I'm
operating through), which has the pi chat. The other is a Chrome window
(unviewable). Let me screenshot the active wezterm window to see the current
state of the pi chat UI.

╰─ ✓ completed

              🤖 铺绢… for 27s · 🧠

              󰫽󰫿󰫼󰫺󰫽󰬁
│
```

**Line count**: ~38 lines of content + ~12 lines of border chrome = **50 lines**

### After (proposed)

```
π

▾  bash
  xdotool search --name "nvim" 2>/dev/null; echo "---wezterm---"; xdotool sear…

  …5 lines
    39845891

  󰟶 Thought for 4s
  There are two windows with "nvim" in the name: 48234500 and 39845891. The
  wezterm window is 39845891 (active). Let me get the names of both to understand.
  48234500 might be a nested/inner nvim or the pi chat. Let me check window names
  and geometry.

  Actually 39845891 is the active wezterm window — that's likely the main nvim I'm
  operating in (the pi chat). Let me screenshot it. But the pi chat might be a
  side panel within it. Let me get window info first.

▾  bash
  for w in 48234500 39845891; do echo "═══ $w ═══"; xdotool getwindowname "$w"…

  …9 lines
      Map State: IsViewable

  󰟶 Thinking…
  The active viewable window is 39845891 — a WezTerm running nvim (the one I'm
  operating through), which has the pi chat. The other is a Chrome window
  (unviewable). Let me screenshot the active wezterm window to see the current
  state of the pi chat UI.

  󰚩 铺绢… 27s · 󰟶

 prompt
│
```

**Line count**: ~38 lines of content + **0 lines of border chrome** = **38 lines**

**Savings**: 12 lines (24% reduction). More importantly: the visual noise from `╭│├╰` characters is **eliminated entirely**. The eye flows through content without parsing structural glyphs.

---

## 11 · Diff Review Panel

The diff review panel (`diff.lua`) is a separate window with its own winbar. It is **not part of this redesign pass** — its current design (side-by-side or unified diff with accept/reject keymaps) is functional and visually distinct from the chat history. The only change that touches it:

- **Winbar color**: currently `bg = Function.fg` (accent). This is correct and consistent with the accent-color-for-agent-actions principle. **No change.**

---

## 12 · Dialog / Extension UI

Floating dialogs (`dialog.lua`) use `PiFloat` / `PiFloatBorder` / `PiDialogTitle`. These are **not part of this redesign pass** — they are modal overlays with their own visual context. **No change.**

---

## 13 · Implementation Phases

The changes are ordered by impact and risk:

### Phase 1 — Tool Block De-framing (highest impact, medium risk)
- Replace `M.GLYPHS` in `tools.lua`
- Remove footer line rendering for successful tools
- Move spinner to header-line virtual text
- Update `apply_collapsed_extmarks` for new glyph set
- Update all `set_border` call sites

### Phase 2 — Icon Unification (low risk)
- Replace emoji `🧠` with `config.labels.thinking` in all code paths
- Audit all string literals for raw emoji
- Verify `config.labels.agent_response` renders as nerd font, not emoji

### Phase 3 — Thinking Block Indentation (low risk)
- Add 2-space indent to thinking body lines in `_build_thinking_block`
- Update `_apply_thinking_hl` to account for indent offset

### Phase 4 — Status Line Alignment (low risk)
- Remove centering logic from `_update_status_extmark`
- Change to left-aligned with 2-space indent
- Drop "for" prefix from elapsed time

### Phase 5 — Prompt Title (trivial)
- Change `config.defaults.panels.prompt.title` from PUA glyphs to `"prompt"`
- Change `config.defaults.panels.attachments.title` from PUA glyphs to `"attached"`

### Phase 6 — Spacing & Rhythm (low risk)
- Ensure 1 blank line after every tool block
- Ensure 1 blank line after every thinking block
- Verify turn-separator blank lines are consistent

---

## 14 · What Does NOT Change

Explicitly out of scope:

- **Message pill labels** (user/agent) — they work, they're infrequent, they anchor turns
- **Statusline** (bottom bar with model/tokens/thinking) — already the cleanest element
- **Markdown rendering** — treesitter + render-markdown engine is orthogonal to chrome design
- **Color scheme** — all colors derive from the user's colorscheme; we define no hex values
- **Layout modes** (side/float/zen) — window management is orthogonal to content design
- **Keybindings** — no interaction model changes
- **Diff review panel** — separate visual context, functional as-is
- **Dialog/extension UI** — modal overlays, separate visual context

---

## 15 · Design Rationale Summary

| Decision | Why |
|----------|-----|
| Remove box borders | They are the #1 source of visual noise. 30% of tool-block lines are pure chrome. Indentation conveys the same grouping without glyphs. |
| Silent success | "✓ completed" on every tool is the terminal equivalent of a loading spinner that says "100% complete" — it tells you what you already know. Errors are the exception that needs calling out. |
| Unified icons | Mixing emoji + nerd font creates two visual weights and two color behaviors (emoji are always full-color). One family = one weight = one mental model. |
| Left-aligned status | Centered text in a left-aligned buffer creates a broken axis. The eye has to re-calibrate on every status line. Left-align keeps one reading column. |
| Functional titles | "P R O M P T" in PUA glyphs is a decorative banner in a tool that values function. A simple word in the winbar is quieter and clearer. |
| Indented thinking | Thinking is subordinate to agent prose. Indentation signals hierarchy without color or borders — the same mechanism used for tool bodies. |
| Breathing lines | One blank line after blocks gives the eye a rest point. Zero blank lines within blocks keeps related content grouped. This is the minimum rhythm that prevents the "wall of text" effect without wasting vertical space. |
