# Attention & dialogs

Extensions can ask the user for input mid-turn — selects, confirms, free-form text, multi-line editors, and the [diff review](diff-review.md) are all different flavors of the same thing under the hood: an `extension_ui_request` that blocks the agent until the user responds. Agent Workbench calls these **attention requests**. Selects and confirms use a session-local prompt mode; other request types share the existing attention queue and dialog surfaces.

## Immediate vs queued

When a request arrives, Agent Workbench decides between showing it immediately and queueing it:

- **Immediate** — if no request is already active, the request opens without requiring focus in the π prompt. Selects and confirms move focus to Prompt and replace its visible compose text without losing its draft; diffs and text inputs open their dedicated UI.
- **Queued** — when that session already has an active request, or when a free-form input/editor would take over a non-empty compose draft, the request is added to a per-session FIFO queue. An attention indicator lights up in the statusline, and a notification appears so you don't lose track of it. Agent stays blocked on that request regardless.

Queued requests can be opened on demand with:

- `:AgentWorkbenchAttention` — open the oldest queued request across all tabs, switching to its owning tab before activating the session. If that tab was closed, current tab stays active.
- `pi.attention()` — same thing from Lua.

Both are no-ops when there's nothing queued.

## Auto-open on prompt focus

By default (`attention.auto_open_on_prompt_focus = true`), focusing π prompt pulls next queued request for current tab automatically when no request is already active. Existing compose draft is preserved while select/confirm mode is active and restored afterward.

Disable this if you prefer to control the timing manually:

```lua
require("agent-workbench").setup({
    attention = {
        auto_open_on_prompt_focus = false,
    },
})
```

With auto-open disabled, you drain the queue explicitly with `:AgentWorkbenchAttention`.

## Completion notification

`attention.notify_on_completion` (default `true`) shows a three-second info notification when the agent finishes a turn and the π prompt isn't focused:

> Agent finished - waiting for your input

Handy if you are working on something else, either code or talk with another agent in a neighbor tab, while the agent is working and want a heads-up when it's done. Disable with `attention.notify_on_completion = false`.

## Querying the queue

A few Lua functions let you inspect the attention state without opening anything — useful for custom statuslines, tabline indicators, or extension widgets:

```lua
local pi = require("agent-workbench")

pi.attention_count()         -- pending requests for the current tab
pi.attention_count(tab_id)   -- pending requests for a specific tab
pi.attention_total()         -- pending requests across all tabs
pi.has_attention()           -- boolean shortcut for the current tab
pi.attention_state()         -- full state snapshot
```

Agent Workbench also fires a `User` autocmd when a new request is added to the queue:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AgentWorkbenchAttentionRequested",
    callback = function(event)
        local data = event.data
        -- data.tab, data.kind ("diff"|"select"|"confirm"|"input"|"editor"),
        -- data.tab_count, data.total_count
    end,
})
```

The built-in `attention` statusline component already uses this state — see [Statusline](usage.md#statusline) for its icon/counter options.

## Prompt request mode

Extension selects and confirms switch their owning session's `pi-chat-prompt` buffer from `compose` mode to `request` mode. Prompt title becomes `CHOOSE` or `CONFIRM`; question and options render read-only in that session's prompt window. New RPC peers send `optionDetails` beside the compatible string option list, preserving each option's label, description, preview, and value without encoding UI data in the title. Agent Workbench preserves the selected preview's original lines in a virtual right-hand pane aligned with the option list and updates that pane during navigation. Narrow prompt windows place the same multiline preview below the options instead of overlapping or flattening it. Embedded `--- N. ... preview ---` title blocks remain accepted only as compatibility input from older `ask_user_question` releases. Confirming an option returns its value or legacy option string, never its preview. This keeps parallel agents distinguishable and prevents `<Esc>` from accidentally cancelling a blocking request.

| Key | Action |
| --- | --- |
| `j`, `k`, `↑`, `↓` | Move selection |
| `<CR>` | Confirm selected option |
| `<Esc>` | Leave Insert mode only; request stays active |
| `<C-c>` | Explicitly cancel request |

Compose draft, cursor, attachments, and prompt history remain untouched. After response, prompt returns to `compose` mode and restores draft. Multiple requests for one session drain FIFO. Requests in other sessions remain attached to those sessions and are exposed through workspace attention indicators.

Plugin-local model/thinking/diff-note pickers still use `vim.ui.select`. Inputs and editors remain custom floating windows with `pi-dialog` filetype. Style and keys for these floats live under `dialog` in `setup()`:

```lua
require("agent-workbench").setup({
    dialog = {
        border = "rounded",
        -- Max size: fraction (<1) of editor, or columns/lines (>=1).
        max_width = 0.8,
        max_height = 0.8,
        keys = {
            -- Additional keys, on top of the built-in defaults below.
            -- See the Key specs section for the format.
            confirm = { { "<C-CR>", modes = { "n", "i" } } },
            cancel = nil,
        },
    },
})
```

Input and info dialogs come with a base set of keybindings; `dialog.keys` adds to them rather than replacing them:

| Action | Built-in keys | What it does |
| --- | --- | --- |
| `confirm` | `<CR>` (normal + insert) | Submit the value / close the info dialog |
| `cancel` | `<Esc>`, `q` (normal) | Dismiss without responding (extension sees a cancellation) |

Anything you add under `dialog.keys.<action>` is bound in addition to the built-ins, so you can keep the defaults and just add your preferred shortcuts on top. See [Key specs](keymaps.md#key-specs) for the accepted formats.
