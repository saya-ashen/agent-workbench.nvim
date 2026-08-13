# Usage

This page walks through how `pi2.nvim` actually works in practice. Each subsection is independent — jump straight to what you need.

- [Chat & layouts](#chat--layouts)
- [Prompt](#prompt)
- [Aborting with double `<Esc>`](#aborting-with-double-esc)
- [Direct bash mode (`!`)](#direct-bash-mode-)
- [Prompt history](#prompt-history)
- [Draft persistence](#draft-persistence)
- [Mentions](#mentions)
- [Dynamic mentions](#dynamic-mentions)
- [Slash commands](#slash-commands)
- [Completion](#completion)
- [Attachments](#attachments)
- [Zen mode](#zen-mode)
- [Statusline](#statusline)
- [Navigation](#navigation)
- [Quickfix](#quickfix)
- [Tool blocks](#tool-blocks)
- [Models](#models)
- [Thinking](#thinking)
- [Markdown rendering](#markdown-rendering)
- [Buffer reload](#buffer-reload)
- [Startup block](#startup-block)

Related pages: [Sessions](sessions.md) · [Diff review](diff-review.md) · [Attention & dialogs](attention.md) · [Extensions](extensions.md) · [Configuration](configuration.md) · [Keymaps](keymaps.md)

## Chat & layouts

The chat opens in a full-width `buffer` layout by default: history fills current editor window and prompt uses a small bottom split. `side` and `float` remain available through `layout.default` or `:Pi layout=side|float`.

**Full buffer** keeps agent history in current editor window, with prompt in bottom split. This makes transcript navigation and block folding behave like normal Neovim buffer work.

**Floating window** opens π as a centered floating window over the editor. Good for the parts of the workflow where the conversation _is_ the work — planning, brainstorming, debugging out loud, writing specs — and you don't need the code visible at the same time. Having the chat comfortably wide and centered is much easier on your neck than spending forty minutes craned toward a side panel on the right.

**Side panel** opens π as a vertical split anchored to the left or right edge of the editor (or to the bottom).

Each chat contains three panels:

| Panel | Filetype | Role |
| --- | --- | --- |
| `history` | `pi-chat-history` | Rendered conversation: messages, tools, diffs, thinking blocks. Read-only. |
| `prompt` | `pi-chat-prompt` | Where you type the next message. Multi-line buffer. |
| `attachments` | `pi-chat-attachments` | Pending image attachments queued for the next message. |

The filetype names are stable — you can target them from your own `FileType` autocmds (see [Keymaps](keymaps.md) for an example). Input and info dialog buffers use the stable `pi-dialog` filetype, so completion plugins can be disabled there without affecting the prompt.

Use `:PiToggleLayout` to swap `buffer` ↔ `float` without losing conversation, and `:PiToggleChat` to hide and re-show chat windows. `side` remains available through explicit layout selection. Neither stops agent. To shut down underlying `pi --mode rpc`, use `:PiStop`.

Each panel has a winbar with a title controlled by `panels.<panel>.title` (a string; defaults: `π`, `prompt`, `attached`). In side layout, the winbar can be disabled per-panel with `layout.side.panels.<panel>.winbar = false`. Separately, `panels.<panel>.name = function(tab_id) return ... end` lets you compute the underlying buffer name per tab — useful for distinguishing multiple π conversations in `:buffers`, statuslines, or tab bars. The prompt panel has an extra `panels.prompt.bash_title`: while the prompt text starts with `!` (direct bash mode, see below), the prompt title switches to this string and is drawn with the `PiChatPromptWinbarBashTitle` / `PiChatPromptFloatBashTitle` highlight groups (a distinct foreground color, derived from `WarningMsg` by default) so it's obvious you're about to run a shell command rather than message the agent.

### Block folding

History uses normal editor-window line-number settings and exposes native `foldmethod=expr` structure with a one-column fold gutter. Completed tool output stays complete in the transcript buffer; native window folds control visibility without replacing content.

Assistant turns split into **Agent Activity** and **Agent Output** sections. Thinking, tool calls, tool results, and intermediate prose belong to Activity and fold automatically when the turn completes. The final prose belongs to Output. The two most recent Outputs stay open by default; older Outputs close once as new turns arrive. Manually reopening an older Output is respected by later updates. Pure-text responses contain only Agent Output.

History blocks support local-plugin style normal-mode controls:

- `<Tab>`: open complete long tool output in a separate viewer; toggle short output inline
- `za`, `<CR>`, or `o`: toggle long-output preview or ordinary inline fold
- `zo`: show long-output preview or expand ordinary block
- `zc`: hide long-output preview or collapse ordinary block

Controls apply to startup, thinking, compaction, and tool blocks.

## Prompt

Prompt buffer (`pi-chat-prompt`) has two session-local modes. `compose` is regular multi-line message editing. `request` temporarily renders extension select/confirm questions and options in same prompt area. Compose text and cursor are preserved and restored after request resolves, so parallel agents keep requests attached to correct session. See [Attention & dialogs](attention.md#prompt-request-mode).

Prompt clears after each message submission, but contents persist across `:PiToggleChat`, layout toggles, and tab switches. Window auto-resizes between 8 and 15 rows.

Three buffer-local mappings control submission:

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | normal, insert | Submit the prompt |
| `<A-CR>` | normal, insert | Submit as a follow-up |
| `<S-CR>` | insert | Insert a newline |

> [!NOTE]
> These keys are currently hardcoded. If you'd like them to be configurable, please open an issue.

When the agent is **idle**, `<CR>` and `<A-CR>` behave identically — they both send a regular prompt and start a new turn.

When the agent is **streaming**, the two diverge. Both options queue your message rather than sending it straight to the LLM — the difference is _when_ the queued message is fed back in:

- `<CR>` sends a **steer**. The agent finishes whatever tool calls are currently in flight, and your message is delivered just before the next LLM call. The agent doesn't stop mid-tool-call, but it also doesn't finish the whole task before reading you. Use it when you want to redirect the agent at the earliest possible boundary — e.g. you've spotted that it's going down the wrong path and want to correct course as soon as the current step lands.
- `<A-CR>` sends a **follow-up**. The message waits until the agent has fully finished the current turn (no more tool calls, no pending steers) and is then delivered as the next message. Use it when you want to add something for the agent to address _after_ it's done with the current work, without interrupting the flow.

Both queued messages are rendered in the history with distinct labels (`labels.steer_message` and `labels.follow_up_message`) so you can tell them apart later.

## Aborting with double `<Esc>`

While the agent is **streaming** or **auto-retrying** (statusline shows "Retrying…" — the backoff window after a failed LLM call), pressing `<Esc>` twice in quick succession aborts — the same as `:PiAbort` / `pi.abort()`. During a retry the second `<Esc>` sends the precise `abort_retry` RPC command, which only cancels the backoff; the retry is cancelled and the failed turn ends instead of being retried. The first `<Esc>` arms the gesture and shows a hint in the **statusline center** (temporarily replacing the busy spinner there) — so it stays visible instead of flashing by like a command-line message. The second `<Esc>`, within `abort.timeout` milliseconds, actually aborts. If you don't press a second `<Esc>` in time, the gesture disarms itself and the hint disappears. This works from both insert and normal mode on the prompt buffer, and from normal mode on the history buffer.

When a turn is aborted (by double-`<Esc>`, `:PiAbort`, or `pi.abort()`), the statusline center briefly shows an **Aborted** confirmation (`PiAborted` highlight) for about two seconds, and the completion marker left in the history (`· aborted`) uses that same prominent highlight rather than the muted busy color — so it's obvious the turn was cancelled.

When the agent is **idle**, `<Esc>` keeps its normal behavior (leaves insert mode) and the gesture is inert — no hint, no abort.

Controlled by the `abort` config:

```lua
require("pi").setup({
    abort = {
        enabled = true, -- set false to disable double-<Esc> abort entirely
        timeout = 1500, -- ms window for the second <Esc> to count
        message = "Press <Esc> again to abort", -- hint shown in the statusline center on the first <Esc>
    },
})
```

## Direct bash mode (`!`)

Just like the π TUI, you can run a shell command straight from the prompt by prefixing it with `!` — e.g. `!ls -la` or `!git status`. This mirrors pi's built-in bash mode: the command is executed immediately by the agent backend (via the RPC `bash` command), its output streams into the chat as it arrives, and the result is added to the LLM context on the **next** prompt (so the model can see what you just ran). It runs independently of the agent's streaming state — you can fire a `!` command even while a turn is in progress.

While the prompt text starts with `!` (leading whitespace is ignored), the prompt panel's title switches to `panels.prompt.bash_title` (default `"bash"`) and is drawn in a distinct foreground color, so you can tell at a glance that `<CR>` will run a shell command instead of messaging the agent. Removing the leading `!` switches the title back. In float layout the same switch applies to the prompt window's border title and `winhighlight`.

A few details that match the TUI:

- `!!command` runs the command but **excludes** its output from the LLM context — handy for noisy or private output you don't want the model to see. The block renders dimmer to mark it as excluded.
- Output streams live into a collapsible block (`▾ $ <command>` header, indented output, fold with `<Tab>` like any other block). Multi-line commands show each line under the header. Non-zero exit codes render as `(exit N)`, cancellations as `(cancelled)`, and truncated output notes the full-output temp path.
- Only one direct bash command can run at a time. Submitting another while one is running is rejected with a warning (press `<Esc>` to cancel the running one first, same as the TUI).
- A single `<Esc>` (in either insert or normal mode on the prompt) cancels a running `!` command — the same as `:PiAbortBash` / `pi.abort_bash()`. This is separate from the double-`<Esc>` agent abort above: `<Esc>` cancels a bash command when one is running, and arms the double-`<Esc>` agent abort when the agent is streaming.
- `!` commands are recorded in the prompt history, so `<C-p>` / `<Up>` recalls them like normal prompts.

## Prompt history

Every prompt you submit is recorded (raw, before `@mention` expansion) so you can recall it later, readline-style. Multi-line prompts are stored intact.

| Key | Mode | Action |
| --- | --- | --- |
| `<C-p>` | normal, insert | Recall the previous (older) prompt |
| `<C-n>` | normal, insert | Recall the next (newer) prompt |
| `<Up>` | insert | Recall older — only on the **top** line, so multi-line editing still works |
| `<Down>` | insert | Recall newer — only at the **bottom** line or while already browsing |

Walking up stashes whatever you're currently typing; walking back down past the newest entry restores that draft. Editing the buffer by hand leaves browse mode, so a stray `<Down>` never clobbers your typing. Recall is a no-op while the completion menu is open.

History persists to `stdpath("data")/pi/prompt_history.json` (written atomically) and survives restarts. Configure it under `prompt.history`:

```lua
require("pi").setup({
    prompt = {
        history = {
            enabled = true, -- set false to disable recording/recall entirely
            max = 500,      -- entries kept; oldest are dropped first
            -- path = "...",  -- override the history file location
        },
    },
})
```

## Draft persistence

While [prompt history](#prompt-history) remembers what you've _sent_, draft persistence makes sure you don't lose what you're _typing_. The unsent prompt is saved to `stdpath("data")/pi/draft.txt` as you edit (debounced) and restored into the prompt the next time Neovim starts — so a crash or restart no longer costs you a half-written message. Sending or clearing the prompt removes the stored draft. To avoid surprises, a draft is restored at most once per Neovim process (an in-session `:PiNewSession` won't re-restore a stale draft).

Disable it under `prompt.draft`:

```lua
require("pi").setup({
    prompt = {
        draft = { enabled = false },
    },
})
```

## Mentions

You can refer to files and directories anywhere in your prompt with `@path` mentions. Pi expands them just before sending the message:

| Written | Sent to the agent |
| --- | --- |
| `@lua/pi/init.lua` | `[file: lua/pi/init.lua]` |
| `@lua/pi/init.lua#L42` | `[file: lua/pi/init.lua, line: 42]` |
| `@lua/pi/init.lua#L10-40` | `[file: lua/pi/init.lua, lines: 10-40]` |
| `@lua/pi` | `[directory: lua/pi]` |

The file content itself is **not inlined**. Pi assumes the agent has a `read` tool and lets it pull the content on demand. There are two reasons for this:

1. **Inlined code has no context.** Dropping a snippet into the prompt strips it from its surroundings — the agent loses imports, neighboring functions, the rest of the file, the rest of the project. A reference, on the other hand, lets the agent open the file itself and decide how much context it actually needs.
2. **Mentions are usually woven into a sentence.** A typical prompt looks like _"check if the usage of `Foo` defined at @path/to/foo.rs#L5 makes sense in the function at @path/to/fn.rs#L120-150"_. If every mention expanded into an inline code block, the sentence would fall apart and the agent would have to reconstruct what referred to what. Keeping mentions as references preserves the natural flow of the prompt.

Mentions are validated against the filesystem at send time. Paths are resolved relative to the current working directory. Anything that doesn't resolve to an existing file or directory is sent through unchanged, so a stray `@todo` in your message stays a stray `@todo`.

Trailing punctuation works the way you'd expect: `(@lua/pi/init.lua)` and `Look at @lua/pi/init.lua.` both expand cleanly without dragging the punctuation into the path.

While typing, `@mentions` are highlighted in the prompt buffer so you can see at a glance which references will expand.

`:PiSendMention` inserts an `@mention` for the current buffer at the cursor position in the π prompt, opening the chat if needed. In normal mode it mentions the buffer as a whole; in visual mode (or with a `:'<,'>PiSendMention` range) it mentions just the selected lines. The command handles spacing around the insertion so you don't end up with double spaces or missing separators. It's also exposed as `pi.send_mention(args, opts)` from Lua — see the [Keymaps](keymaps.md) example for typical bindings.

> [!TIP]
> Because `@mentions` expand to `[file: ..., line: ...]` / `[file: ..., lines: ...]`, it's worth teaching the agent to re-read the exact reference before answering. Consider adding the following to your global `AGENTS.md` (or equivalent):
>
> ```md
> ## File and line references
>
> When the user references a file with `[file: ...]` and a specific line or line range, you must re-read that exact reference immediately before answering, even if the file was read earlier in the conversation.
> ```

## Dynamic mentions

Some context is not a file — it is generated on demand: the current diff, recent commits, LSP errors, the quickfix list. Dynamic mentions materialize that state and attach it to the message when you send it:

| Mention | Attached content |
| --- | --- |
| `@git-diff` | `git diff HEAD` output (staged + unstaged changes), fenced as `diff` |
| `@git-log` | `git log --oneline -20` (recent commits) |
| `@lsp-errors` | all LSP diagnostics with ERROR severity, as `path:lnum:col: message` lines |
| `@quickfix` | the current quickfix list (title + `path:lnum:col: text` entries) |

Unlike file mentions, a dynamic mention is lifted out of your sentence: its content is appended to the end of the message as a fenced `<context>` block. _"review @git-diff please"_ reaches the agent as `review please` followed by a block with the actual diff. A mention whose provider produces nothing (clean tree, empty quickfix, no errors) vanishes silently. Mentioning the same provider twice attaches it only once.

Dynamic mentions appear in `@`-completion ahead of file matches and are highlighted in the prompt exactly like file mentions.

You can register your own providers — any `name → function returning text` pair becomes an `@name` mention:

```lua
require("pi").setup({
    mention_providers = {
        todos = {
            fn = function()
                return vim.fn.system("grep -rn TODO src/")
            end,
            description = "open TODOs in src/", -- shown in the completion menu
            lang = "text", -- fence language for the attached block (optional)
        },
        -- plain functions work too
        branch = function()
            return vim.trim(vim.fn.system("git branch --show-current"))
        end,
    },
})
```

Output is trimmed and capped at 256 KB per provider (larger payloads are truncated with a marker). A provider that errors never breaks the send — the failure is reported as a warning and the mention attaches nothing.

## Slash commands

Slash commands come from pi2.nvim's local controls and the **pi backend**. Local controls mirror pi's TUI commands: `/new`, `/resume`, `/model`, `/thinking`, `/compact`, `/name`, `/session`, and `/abort`. Backend commands cover three sources:

- **Local controls** — handled directly by pi2.nvim and mapped to existing APIs.
- **Extension commands** — registered by pi extensions (e.g. `/permission-toggle-auto-accept`).
- **Prompt templates** — reusable prompt snippets, expanded server-side before being sent to the LLM.
- **Skills** — invoked as `/skill:name`, also expanded server-side.

pi2.nvim fetches backend command list from running session over RPC and merges it with local controls. Backend set refreshes periodically, so extension/template/skill commands depend on current session.

A local command with arguments uses them when pi2.nvim supports direct execution. Unsupported arguments are ignored while command still runs locally; built-in command names are never forwarded to backend as prompts.

To invoke a backend command, type it on the **first line** of the prompt:

```
/permission-toggle-auto-accept
```

Arguments, if the command takes any, follow on the same line:

```
/some-command arg1 arg2
```

Only the first line is recognized as a command — everything else in the same message is treated as plain prompt text. This is a [pi backend convention](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md#get_commands), not a pi2.nvim restriction. If you want a command and a regular prompt to take effect together, send them as two separate messages.

One command is handled locally instead of being sent: a bare `/tree` opens the [session tree navigator](sessions.md#session-tree-navigation-pitree) (`:PiTree`), mirroring the TUI's built-in `/tree`.

That said, this only applies to the explicit `/command` invocation path. Skills in particular are surfaced to the model as part of the system context: per the [Agent Skills spec](https://agentskills.io/specification), each skill's `name` and `description` are loaded at startup for _all_ available skills ("progressive disclosure"), and the full `SKILL.md` body is only loaded once the model decides to activate that skill. As a result, most models will pick up the right skill even when you _mention_ it inline ("please use the `commit` skill to write the message"), without you having to invoke `/skill:commit` explicitly. How reliably this works depends on the model and on how much other context it's juggling, so for anything load-bearing it's still safer to invoke the command explicitly on the first line.

While typing, the prompt buffer highlights matching local and backend `/commands` in real time. Backend commands still require the command cache to be populated; it is fetched the first time chat opens and refreshed every 30 seconds.

You can also invoke a command programmatically from Lua, without going through the prompt buffer:

```lua
require("pi").invoke("/permission-toggle-auto-accept")
-- the leading slash is optional:
require("pi").invoke("permission-toggle-auto-accept")
```

This is useful for binding commands directly to keymaps:

```lua
vim.keymap.set(
    "n",
    "<Leader>pt",
    function()
        require("pi").invoke("/permission-toggle-auto-accept")
    end,
    { desc = "Pi toggle auto-accept" },
)
```

Note that `pi.invoke` requires an active session — if no chat is running for the current tab, it will warn and do nothing.

## Completion

The π prompt buffer ships with completion for both `@mentions` and `/commands` out of the box. Two integrations are provided:

**1. Built-in completion (always on).** Every π prompt buffer has both `completefunc` and `omnifunc` set. Typing `/` on the first line or `@` anywhere opens the completion popup automatically, without extra configuration. You can also trigger the same source manually in insert mode with:

```
<C-x><C-u>
```

It will:

- Complete `@path` mentions against project files (resolved relative to the current working directory), plus [dynamic mention providers](#dynamic-mentions) (`@git-diff`, `@git-log`, `@lsp-errors`, `@quickfix`, and any custom `mention_providers`) ahead of file matches.
- Complete `/commands` against the backend's command list — but only when the cursor is on the first line of the prompt and that line starts with `/`.

The completion popup shows source metadata for `/commands` (`extension`, `prompt`, `skill`) and the command description when available.

**2. `blink.cmp` source (optional).** If you use [blink.cmp](https://github.com/Saghen/blink.cmp), pi2.nvim ships a source at `pi.completion.blink` that integrates natively with the blink popup, including auto-trigger on `@`, `/`, and `.`. Scope it to the π prompt filetype with `per_filetype` so it doesn't interfere with completion in your regular files:

```lua
require("blink.cmp").setup({
    sources = {
        per_filetype = {
            ["pi-chat-prompt"] = { "pi" },
        },
        providers = {
            pi = { name = "Pi", module = "pi.completion.blink" },
        },
    },
})
```

Other completion plugins (nvim-cmp, etc.) aren't shipped as first-class sources, but they can usually bridge the built-in `completefunc` via their `omni`/`completefunc` source adapters. If you'd like a native source for another plugin, please open an issue.

## Attachments

π supports image attachments. Anything you attach is queued in the dedicated **attachments panel** (`pi-chat-attachments`) below the prompt and sent along with your next message as base64-encoded image data. Each entry shows the image's byte size (e.g. `󰫮 shot.png (1.2 MB)`) — the size of the data that will actually be sent.

Supported formats: `png`, `jpg`/`jpeg`, `gif`, `webp`, `svg`.

There are three ways to attach an image:

**1. From a file path** with `:PiAttachImage`:

```vim
:PiAttachImage path/to/screenshot.png
```

The path is resolved relative to the current working directory. Also exposed as `pi.attach_image(path)` from Lua.

**2. From the clipboard** with `:PiPasteImage`:

```vim
:PiPasteImage
```

This requires [`HakonHarnes/img-clip.nvim`](https://github.com/HakonHarnes/img-clip.nvim) and a system clipboard tool (`pngpaste` on macOS, `xclip` on X11, `wl-paste` on Wayland). Clipboard images are auto-named `cb-image-1.png`, `cb-image-2.png`, and so on. Also exposed as `pi.paste_image()` from Lua.

You normally don't need the command: with `prompt.paste_image = true` (the default), π wraps Neovim's global paste handler (`vim.paste`) and inspects anything pasted into the prompt. If the clipboard holds an image, it is attached automatically and the text paste is cancelled; any other paste is inserted as usual. This works for GUI paste (`nvim_paste`, e.g. `<D-v>`/`<C-v>` in Neovide). In a plain terminal the system paste shortcut is handled by the terminal itself and only delivers text, so an image-only clipboard may not trigger it — there, use `:PiPasteImage` (or map a key to `pi.paste_image()`) explicitly. Set `prompt.paste_image = false` to disable the interception entirely.

**3. By drag-and-drop**, by dragging an image file into the π prompt buffer from your OS file manager. π intercepts the drop, recognizes it as a file path with a supported image extension, and adds it as an attachment instead of pasting the path as text. Plain-text pastes are not affected.

### Image compression

With `prompt.image_compress.enable = true` (the default), attachable images (`png`/`jpeg`/`webp` — `svg` and `gif` are never touched) are compressed asynchronously before they are queued: downscaled to `max_dimension` on the longest side (default 1568px, matching common provider recommendations) and, optionally, re-encoded (`format`) at a given `quality`. The size shown in the attachments panel is the post-compression size — what will actually be sent. Compression never makes things worse: if the result would not be smaller than the input, the original is attached instead.

The work is done by an external tool, probed in order `sips` (built into macOS) → `magick` (ImageMagick) → `ffmpeg`. With none of them available the original image is attached silently; a failed compression attaches the original with a warning. By default dropped/attached files are compressed too — set `scope = "clipboard"` to only compress clipboard pastes.

Once attached, items appear in the attachments panel with an icon, the filename, and the byte size. To remove an entry, focus the attachments panel, put the cursor on the line you want to drop, and press `dd` or `x`. Both buffer-local mappings remove the item under the cursor.

Attachments are cleared automatically when the message is sent. If you want to discard the queue without sending, just delete each entry with `dd`/`x`.

## Zen mode

Zen mode is a full-screen overlay that promotes the π prompt to a centered floating window over a dimmed backdrop. The history, attachments, and the rest of your editor disappear behind the backdrop, leaving only the prompt visible. It's the right mode when you need to compose a long message — a multi-paragraph spec, a detailed bug report, a planning brain dump — without the rest of the UI distracting you.

While zen is active:

- The prompt is centered horizontally and spans the full editor height.
- Width comes from `zen.width` (in columns); if unset, π falls back to your `'textwidth'`, then to 80.
- You can't accidentally navigate away — π bounces focus back to the prompt if you try to leave it. Floating windows like dialogs and completion popups are still allowed.
- The geometry auto-recomputes on `VimResized`.
- Submitting (`<CR>` / `<A-CR>`) automatically exits zen and returns you to the normal chat layout.

### Configuring zen keys

Zen mode has **no default keymap** — you have to opt in by setting at least `zen.keys.toggle`. Optionally, you can also set `zen.keys.exit` to bind extra keys that only exit zen (the toggle key always works for both directions).

```lua
require("pi").setup({
    zen = {
        -- Optional: width in columns. nil = textwidth, then 80.
        width = 100,
        keys = {
            -- Toggle: enters zen when inactive, exits when active.
            toggle = { "<M-z>", modes = { "n", "i" } },
            -- Exit-only: any of these keys leaves zen but doesn't enter it.
            exit = {
                { "<Esc>", modes = "n" },
            },
        },
    },
})
```

The toggle key is registered as a permanent buffer-local mapping on the prompt buffer. Exit keys are bound only while zen is active, and any pre-existing buffer-local mappings on the same `lhs` are saved and restored when zen exits, so they don't get clobbered. See [Key specs](keymaps.md#key-specs) for the format of `zen.keys.toggle` / `zen.keys.exit` values.

## Statusline

π keeps session status data available to prompt winbar and Lua components. Live spinner, rotating verb, elapsed time, and thinking marker render after latest history output while agent runs. Separate configurable status line pinned to bottom of prompt buffer is disabled by default because winbar already shows running state, model, thinking level, context usage, and cwd. Double-`<Esc>` abort hint and transient `Aborted` confirmation still use bottom row when needed. Set `statusline.enabled = true` to restore expanded bottom row with token counts, cost, pending attention, auto-compaction state, spinner, and extension components.

The expanded layout is split into **left**, **center**, and **right** groups. Each group is just an array of items, and items can be:

- **A built-in component name** — a string matching one of the built-ins listed below.
- **A literal separator** — any other string, rendered between two _visible_ components as-is. If the next component is hidden, the separator is dropped too, so `{ "a", "  ", "b" }` automatically collapses to just `a` when `b` has nothing to show.
- **A custom component function** — `function(state) -> string|chunks|nil`. See below.

```lua
require("pi").setup({
    statusline = {
        enabled = true,
        layout = {
            left   = { "context", "  ", "cost", "  ", "attention", "  ", "queue" },
            center = { "spinner" },
            right  = { "model", "   ", "thinking" },
        },
    },
})
```

The **center** group is centered in the window and has placement priority: when the window is too narrow for everything, the left/right groups are truncated into whatever space remains on either side of the center. With no visible center component, the layout falls back to plain left/right behavior (left has priority; right is truncated first).

### Built-in components

| Name | Example output | When it's visible |
| --- | --- | --- |
| `tokens` | `↑3.8k ↓58k` | Total input/output tokens used this session |
| `cache` | `R7.2M W416k` | Total prompt-cache read/write |
| `cost` | `$7.665` | Session cost is greater than zero |
| `context` | `63.9%/200k` | Current context window usage — percentage + total |
| `compaction` | 󰏗 | Auto-compaction is enabled — the same icon as the compaction summary label |
| `attention` | `󰵚` / `󰵚 2` | There's at least one pending attention request |
| `model` | `claude-opus-4-6` | A model is active |
| `thinking` | `xhigh` / `thinking off` | The current model supports reasoning |
| `spinner` | `⠋ Working… 12s · Thinking` | The agent is busy. While the double-<Esc> abort gesture is armed, the hint temporarily replaces the spinner; an `Aborted` confirmation outranks both |
| `queue` | `⏵ 2` | There are pending steer/follow-up messages |

Any component that has nothing to show returns `nil` and is silently skipped (along with its adjacent separator).

### Component config

Per-component options live under `statusline.components.<name>`:

```lua
statusline = {
    components = {
        -- Every built-in takes an `icon` prefix. Set to `false` to disable.
        compaction = { icon = false },
        model = { icon = "󰚩" },

        -- `context` supports warning / error thresholds as percentages
        -- of the model's context window. When crossed, the value is
        -- rendered in `PiStatusLineWarning` / `PiStatusLineError`.
        context = { icon = "", warn = 70, error = 90 },

        -- `cost` supports the same thresholds as raw numbers.
        -- cost = { icon = "", warn = 5, error = 10 },

        -- `attention` can show a numeric counter instead of the icon.
        attention = { icon = "󰵚", counter = false },
    },
},
```

### Custom components

A custom component is a function that receives the current statusline state and returns either a string, a list of styled chunks, or `nil` to hide itself:

```lua
---@param state pi.StatusLineState
---@return string|string[][]|nil text
---@return string?             hl
local function my_component(state)
    -- ...
end
```

The `state` table exposes everything the built-ins see — model info, thinking level, token totals, cost, context usage, a `state.extensions` map of per-extension status values (populated via the RPC `setStatus` call from extensions), plus the busy/queue status: `state.busy` (spinner display model: `frame`, `text`, `elapsed`, `thinking`), `state.queue_count`, `state.abort_hint`, and `state.aborted_notice`.

Drop a custom component anywhere in the layout array. For example, surfacing a status from an extension:

```lua
statusline = {
    layout = {
        left = {
            "context",
            "  ",
            function(state)
                if state.extensions["permission"] then
                    return "󰐌", "PiStatusLineOn"
                end
            end,
            "  ",
            "attention",
        },
        right = { "model", "   ", "thinking" },
    },
}
```

Return shapes:

- `"some text"` — single chunk, default highlight (`PiStatusLine`).
- `"some text", "MyHl"` — single chunk with an explicit highlight group.
- `{ { "part1", "Hl1" }, { "part2", "Hl2" } }` — multiple chunks with per-chunk highlights.
- `nil` — hide the component (and any adjacent separator).

## Session stats (`:PiSessionStats`)

`:PiSessionStats` opens a floating dashboard with the current session's numbers, mirroring the TUI's `/session` panel. The data comes from two RPC calls — `get_session_stats` (aggregates) and `get_entries` (the full entry list, used for the per-model cost breakdown) — so it works for any session state, including resumed ones.

```
┌─ Pi Session Stats ────────────────────────────────┐
│ File  ~/.local/share/pi/sessions/abc123.jsonl     │
│ ID    abc123                                      │
│                                                   │
│ Messages                                         │
│   User 5 · Assistant 7 · Tools 12 calls / 11 res  │
│                                                   │
│ Tokens                                           │
│   Input    50k                                   │
│   Cached   40k  (42.1% hit)                      │
│   Uncached 55k  (incl. 5.0k writes)              │
│   Output   10k                                   │
│   Total    105k                                  │
│                                                   │
│ Cost  $0.450                                     │
│   deepseek/deepseek-chat       $0.281 ██████░░░░  │
│   anthropic/claude-3.5-sonnet  $0.148 ███░░░░░░░  │
│   Tools/summaries              $0.021 ░░░░░░░░░░  │
│   Cache re-billed  $0.012  (12k tokens, 3 miss…   │
│                                                   │
│ Context                                           │
│   60k / 200k                                      │
│   █████░░░░░░░░░░░  30.0%                         │
└───────────────────────────────────────────────────┘
```

Sections:

- **Identity** — session file (truncated) and ID.
- **Messages** — user/assistant/tool call counts.
- **Tokens** — input/output/total; when the provider reports cache activity, the prompt is split into `Cached` (with hit rate) and `Uncached` (including cache writes).
- **Cost** — the total, plus a per-model breakdown: each assistant response is attributed to its actual `provider/responseModel` (so mid-session model switches show up), and tool results / compaction / branch summaries land in a shared `Tools/summaries` bucket. Bars are proportional to the total. When entries are unavailable (e.g. `get_entries` fails) the panel degrades to the aggregate view without the breakdown.
- **Cache re-billed** — prompt tokens that were in the previous turn but were re-billed instead of served from cache (the TUI's cache-waste computation), with the extra dollars when the session data reports cache-read pricing.
- **Context** — current context-window usage with a threshold-colored bar (yellow above 70%, red above 90%, like the statusline `context` component); shows `?` until the first response after a compaction.

The command is a silent no-op without an active session. `q`/`<Esc>`/`<CR>` close the panel; closing any of the panel's windows closes the rest.

## Navigation

Moving between π panels and scrolling the history without leaving the prompt are some of the most common things you do during a session, so they're worth setting up properly. As with the rest of [Keymaps](keymaps.md), pi2.nvim doesn't bind these by default — it just exposes the API and lets you wire it into the navigation conventions you already use.

### Focus

Three functions move focus between the panels of the current chat:

```lua
local pi = require("pi")

pi.focus_chat_history()      -- jump to the history window
pi.focus_chat_prompt()       -- jump to the prompt window
pi.focus_chat_attachments()  -- jump to the attachments window
```

All three are no-ops when no π session is active in the current tab.

The natural place to bind them is inside the panel buffers themselves, via `FileType` autocmds on `pi-chat-history`, `pi-chat-prompt`, and `pi-chat-attachments`. The example in [Keymaps](keymaps.md) wires `<S-Up>` / `<S-Down>` to walk between panels, but the actual keys are entirely up to you — use whatever you already use for window navigation in the rest of Neovim.

### Scrolling history from the prompt

When the agent is in the middle of a long answer, you usually want to keep typing your next message _while_ peeking at what just scrolled past. Leaving the prompt to scroll the history is awkward, so π lets you scroll the history window from anywhere:

```lua
pi.scroll_chat_history("up")     -- scroll up by 15 lines (default)
pi.scroll_chat_history("down")   -- scroll down by 15 lines
pi.scroll_chat_history("up", 2)  -- finer-grained scroll, 2 lines at a time
```

The second argument is the line count; it defaults to `15` when omitted. Bind both a coarse and a fine-grained step if you want — a fast jump for skimming and a slow nudge for reading.

There are also jump-style helpers:

```lua
pi.scroll_chat_history_to_bottom()                 -- jump to the very latest line
pi.scroll_chat_history_to_first_agent_response()   -- jump to the first agent response in the latest user turn
pi.scroll_chat_history_to_last_agent_response()    -- jump to the last agent response in the latest user turn
```

The agent-response jumps are particularly handy when the agent produced multiple text blocks for one prompt: use the first jump to start reading that turn, or the last jump to revisit the newest block.

Like the focus functions, all scroll functions are no-ops when no session is active. See the [Keymaps](keymaps.md) example for typical bindings inside the prompt buffer.

### Open file under cursor

Tool blocks print the paths they touch, and agent prose often references files. π can open the file on the history line under the cursor in an editor window (never a π panel, so the chat stays visible):

```lua
pi.goto_file_under_cursor() -- returns true when a file was opened
```

It recognizes a bare path (the tool body lines contain exactly the path), an `@path` mention with an optional `#L<line>`, and a `path:line` suffix, and jumps to the indicated line when present. Lines that don't resolve to a real file are ignored. Windows pinned with `winfixbuf` are skipped; when no regular window is usable, π falls back to a fresh split.

`gf` is bound to this on the history buffer by default, so once you move into the history (e.g. `<C-g>h`) you can just `gf` on a path to jump to it.

## Quickfix

When the `grep` tool finishes, its matches are parsed (`path:line[:col]: text`) and loaded into the quickfix list, so you can jump between them with `:cnext` / `:cprev`. The `find` tool's file list can be loaded the same way (disabled by default; `glob` is accepted as an alias for older pi versions that named the tool `glob`).

The quickfix window is **never opened automatically** — use `:copen` to see it. Each list is titled `pi <tool>: <pattern>` (or `pi <tool>` when there is no pattern). Errors are never loaded, and an empty match list leaves your current quickfix state untouched.

```lua
require("pi").setup({
    quickfix = {
        grep = true,  -- grep matches (default on)
        find = false, -- find file list
        glob = false, -- alias of `find` for older pi versions
    },
})
```

## Tool blocks

When the agent invokes a tool, pi2.nvim renders the call inline in the chat history as a **tool block**. Each block stores the tool name, its input summary, and its output. Full-block tools start folded so long tool-heavy turns stay compact; complete output remains in the history buffer and can be opened on demand. Blocks use a fold indicator (`▾`/`▸`) and indentation instead of box-drawing borders — chrome stays out of the way.

```
▾ 󰻂 bash
  rg -n 'foo' lua/

  …12 lines
  lua/pi/init.lua:42: foo = 1
```

Successful tool calls end silently (a blank breathing line); only errors print a status footer. The labels come from `labels.tool`, `labels.tool_failure` in your config. While a full-block tool runs, only its header, argument summary, and spinner remain visible; partial updates do not expand or rewrite the transcript body. Completion renders the authoritative final result once.

### Inline vs full blocks

Tools come in two rendering styles:

- **Inline tools** render as a single line. `read` is the canonical example — it shows `read path/to/file (42 lines)` and stays on one line even when the file is huge, because inlining the content would just be noise. Consecutive inline tool calls are grouped without blank lines between them.
- **Full-block tools** get the multi-line indented block shown above. `bash`, `edit`, `write`, the four [pi-web-access](https://github.com/nicobailon/pi-web-access) tools (`web_search`, `fetch_content`, `source_check`, `get_search_content`), and any tool pi2.nvim doesn't have a dedicated renderer for fall into this category.

### Auto-collapse and `<Tab>`

Every full-block tool has two collapse thresholds:

- `input_visible` — maximum input/argument lines before the block becomes foldable.
- `output_visible` — maximum output lines before the block becomes foldable. Built-in full-block tools use `0`, so any output starts folded.

Running and completed full-block tools stay title-only by default; completion writes the authoritative result into the buffer without opening it. Failed calls use the same fold but keep the failure state visible in the header/footer. For output of 30 lines or fewer, `<Tab>`, `za`, `<CR>`, or `o` toggles the complete output inline. For longer output, `za`, `<CR>`, `o`, or `zo` shows up to four non-empty preview lines plus an omitted-line count while keeping the complete output folded; `zc` restores the title-only state. `<Tab>` opens the complete output in a read-only `pi-tool-output` split instead; use normal Neovim scrolling and search there, then press `q` or `<Esc>` to close it. A `tool_batch` parent remains visible, and each structured child call gets its own persistent icon/argument/status header, fold, preview, and viewer. The same toggle keys still expand and collapse [startup](#startup-block), [thinking](#thinking), and compaction blocks in place.

Bind `pi.toggle_history_blocks()` to expand/collapse all expandable history blocks at once; the [Keymaps](keymaps.md) example uses `<C-o>`.

Built-in thresholds:

| Tool | `input_visible` | `output_visible` | Notes |
| --- | --- | --- | --- |
| `bash` | 1 | 0 | Shows command summary; output starts folded |
| `read` | — | — | Always inline |
| `edit` | 0 | 0 | Renders the proposed diff as folded input; no separate output section |
| `write` | 0 | 0 | Same shape as `edit` for a whole-file write |
| `web_search` | 1 | 0 | [pi-web-access](https://github.com/nicobailon/pi-web-access) — the `query`, or up to three `queries` joined with ` · ` (longer lists truncate as `…(+N)`) |
| `fetch_content` | 1 | 0 | pi-web-access — the `url`, or each entry of `urls` on its own line |
| `source_check` | 1 | 0 | pi-web-access — the `claim` being checked |
| `get_search_content` | 1 | 0 | pi-web-access — `responseId` plus whichever selector is present (`query` / `queryIndex` / `url` / `urlIndex`) |
| (unknown) | 1 | 0 | Default renderer picks the first string argument as summary |

### Status resolution

pi2.nvim picks the tool's display status from the `isError` flag plus any status prefix embedded in the result text by an extension:

| Prefix in result | Display status |
| --- | --- |
| _none_ (and `isError=false`) | `completed` |
| `[accepted]` | `completed` (blocked but the action was applied) |
| `[rejected]` | `rejected` (user or policy refused) |
| `[aborted]` | `aborted` (turn was aborted while the tool was in flight) |
| _none_ (and `isError=true`) | `error` |

The prefix is stripped from the displayed text before the block is rendered, so your users never see the raw `[accepted]` / `[rejected]` markers — just the tool block in the corresponding state. This is how the permission extension in [Diff review](diff-review.md) communicates "accepted but already applied elsewhere" back to pi2.nvim without looking like an error.

### Customization

> [!NOTE]
> Tool renderers are currently **hard-coded** in `lua/pi/ui/chat/tools.lua`. There's no config surface for registering your own renderer or adjusting built-in thresholds. If you'd like any of these to be configurable, please open an issue.

## Models

π can talk to any model your local pi installation has access to — Claude, GPT, Gemini, Groq, OpenRouter, DeepSeek, locally-hosted models, and whatever else you've configured in your pi backend. pi2.nvim doesn't manage credentials or provider wiring; all of that lives in pi itself. What pi2.nvim _does_ give you is a way to shape the set of models you see, cycle through them quickly, and switch mid-session without restarting the chat.

### The `models` list

The top-level `models` option in `setup()` is an optional **preferred list** of model entries. When set, it curates the subset used by the cycle and select commands below. When unset, pi2.nvim falls back to whatever the backend has available.

Each entry is one of:

```lua
require("pi").setup({
    models = {
        -- 1. Plain string — exact model ID match (case-sensitive), or a
        --    canonical "provider/modelId" reference to disambiguate IDs
        --    that exist under several providers.
        "gpt-5.3-codex",
        "opencode-go/deepseek-v4-flash",

        -- 2. Exact match (same as the bare string form for IDs that exist
        --    under a single provider; also accepts the "provider/modelId"
        --    form). For an ID duplicated across providers it takes only the
        --    first matching copy.
        { match = "gpt-5.3-codex", exact = true },

        -- 3. Substring match (case-insensitive), all hits included in order.
        { match = "sonnet" },

        -- 4. Substring match with `latest = true` — picks the single model
        --    whose ID sorts last among the matches. Because provider IDs
        --    usually end in a date suffix, this resolves to the newest.
        { match = "opus", latest = true },
        { match = "gpt", latest = true },
    },
})
```

Entries are resolved at each cycle/select call against the backend's current model list. A warning is logged if an entry matches nothing. In the plain-string form, a bare ID that exists under several providers matches every copy (one entry per provider); in the `exact = true` form it takes only the first matching copy. Either way, use the `provider/modelId` form to pin an entry to a specific provider.

### Cycling and selecting

Three commands, each with a Lua API counterpart:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiCycleModel` | `pi.cycle_model()` | Step to the next model. With `models` configured, cycles within the resolved subset; otherwise uses the backend's own cycle. |
| `:PiSelectModel` | `pi.select_model()` | Open a picker (`vim.ui.select`) to pick a model. With `models` configured, shows only the resolved subset; otherwise falls back to all available models. |
| `:PiSelectModelAll` | `pi.select_model_all()` | Open a picker with **all** backend-available models, ignoring the `models` config. Useful when you want to reach for something you haven't curated into your short list. |

All three take effect immediately and persist for the current session. The active model appears in the `model` statusline component (see [Statusline](#statusline)).

### Session model state

Model changes apply to current session. A resumed session (`:PiResume` / `:PiContinue`) adopts model stored in its session file; a newly created session resolves its initial model from pi backend settings.

Typical setup binds the three operations in the prompt buffer: a fast cycle key, a filtered picker, and an "all models" escape hatch. The [Keymaps](keymaps.md) example uses `<M-m>` / `<M-M>` for cycle and select.

## Thinking

Reasoning-capable models (Claude's extended thinking, OpenAI's `o*` family, OpenAI codex, etc.) emit **thinking blocks** alongside their normal output — an internal monologue the model uses to work through a problem before producing a final answer. pi2.nvim renders these inline in the chat history with a distinct `labels.thinking` marker.

### Visibility

Thinking blocks can be noisy, especially on models that think verbosely or on long turns, so you may want to hide them. pi2.nvim shows them by default; you can flip the default and toggle visibility on demand:

- **Default**: `show_thinking` (bool in `setup()`) — `true` by default.
- **Toggle**: `:PiToggleThinking` / `pi.toggle_thinking()` — show or hide all thinking blocks in the current session.

Hiding thinking doesn't change anything on the backend or affect how the agent works; it's purely a view setting.

### Presentation

When visible, each thinking block renders as a **single header line** with an inline preview of the content (truncated to fit the window width). During streaming the preview rolls with the latest text; once finished it freezes to a head summary. Press `<Tab>` on the header to expand the full multi-line thinking text, and `<Tab>` again to collapse it back. `pi.toggle_history_blocks()` (`<C-o>` in the example keymaps) expands/collapses all blocks — tool and thinking — at once.

### Thinking levels

Beyond visibility, reasoning-capable models let you pick _how much_ the model thinks. pi2.nvim exposes the backend's thinking levels (commonly these six):

```
off | minimal | low | medium | high | xhigh
```

`off` disables reasoning entirely (where the model supports that), and each successive level gives the model more budget to think. `xhigh` is OpenAI codex-max-only; the other five are broadly supported across reasoning models. The currently-active level appears in the `thinking` statusline component (see [Statusline](#statusline)).

Two ways to change it mid-session:

- **Cycle**: `:PiCycleThinking` / `pi.cycle_thinking_level()` — steps to the next level in the list. Handy for a single key you can tap repeatedly.
- **Pick**: `:PiSelectThinking` / `pi.select_thinking_level()` — opens a picker (`vim.ui.select`) with the levels the **current model actually supports** (fetched via the RPC `get_available_thinking_levels` command); if the fetch fails it falls back to the full built-in list.

Both operations require an active session with a reasoning-capable model; on a non-reasoning model they warn _"Current model does not support thinking"_ and leave state unchanged.

Typical setup binds both in the prompt buffer: cycle on a fast key (e.g. `<M-t>`) and pick on a shifted variant (`<M-T>`) — the [Keymaps](keymaps.md) example already does this.

## Markdown rendering

By default chat history uses [markview.nvim](https://github.com/OXY2DEV/markview.nvim): headings, list bullets, code blocks, links, and inline Markdown. Tool output stays fenced so shell content is not misparsed. Choose legacy `render-markdown` or Pi's **builtin** renderer when needed:

```lua
require("pi").setup({
    render = {
        engine = "builtin", -- default: "markview"
    },
})
```

Notes:

- markview.nvim is dependency of default renderer; add it to plugin spec (see [Installation](../README.md#installation)). Missing markview triggers one warning and builtin fallback.
- `render-markdown` remains supported for existing configurations.
- pi only appends its `pi-chat-history` filetype to render-markdown's active `file_types`; your existing render-markdown configuration is left untouched.
- render-markdown drives the rendering through its standard event hooks, so it stays in sync as the agent streams. The `markdown`/`markdown_inline` treesitter parsers it needs ship with Neovim ≥ 0.10.

## Buffer reload

When pi's `edit` or `write` tool modifies a file that is currently open in a Neovim buffer, pi2.nvim can automatically reload that buffer so you always see the latest content without a manual `:edit!`.

The behavior is controlled by `reload.mode`:

| Mode | Behavior |
| ------ | ---------- |
| `"silent"` (default) | Reload unmodified buffers silently. Buffers with unsaved user changes are left untouched. |
| `"notify"` | Same as silent, plus a `vim.notify` message listing which files were reloaded and which were skipped. |
| `false` | Disabled — buffers are never touched. |

```lua
require("pi").setup({
    reload = {
        mode = "silent",  -- or "notify" or false
    },
})
```

A buffer is considered _modified_ when `vim.bo[buf].modified` is true (i.e. the user has unsaved changes). pi2.nvim never overwrites unsaved work — modified buffers are always skipped regardless of mode. Paths are canonicalized (symlinks resolved) before matching, so a file reported through a symlinked path still hits the right buffer.

## Startup block

At the top of every π chat history, pi2.nvim renders a **startup block** — a summary of what the agent has available in the current session. It lives just above the first message and is always in the history buffer.

By default the block starts collapsed with a compact summary. Set `expand_startup_details = true` to start with full details, and toggle it at any time with either:

- `<Tab>` on the block in the history buffer (the same `<Tab>` that expands/collapses tool blocks under the cursor).
- `:PiToggleStartupDetails` / `pi.toggle_startup_details()`.

### What's in it

pi2.nvim pulls the startup content from the backend's `get_commands` RPC response and groups it into up to three built-in sections:

- **`[Skills]`** — skill commands (`skill:name`) loaded for this session, with their location (`[user]` / `[project]` / `[path]`) and source path.
- **`[Prompts]`** — prompt templates (`/name`) loaded for this session, with location and path.
- **`[Extensions]`** — commands registered by pi extensions, with their source paths.

Sections only appear when they have at least one entry, so a bare session with no skills or extensions just shows whatever exists.

> [!WARNING]
> The startup block is currently **incomplete**, and this is an upstream pi limitation rather than something pi2.nvim can fix on its own. The RPC interface only exposes a subset of what the session actually has loaded — for example, loaded extensions that don't register any `/commands` are not surfaced here (even though they're running and active), and memory files (`AGENTS.md`, etc.) aren't reported at all. Treat the block as a useful-but-partial snapshot until the upstream protocol catches up. Until then, the most reliable way for an extension to advertise itself is via [extension startup announcements](extensions.md#extension-startup-announcements) — sending a `:startup` widget with whatever state it wants the user to see.
