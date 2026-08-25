# Keymaps

`Agent Workbench` leaves global keymaps unbound by default. Keymaps tend to be highly personal, and many users already have their own leader-based layouts or other mapping systems. Workflow-local mappings inside Agent Workbench buffers remain available without configuration.

## Recommended global preset

Enable the opt-in preset to add a small set of global entry points under `<Leader>a`:

```lua
require("agent-workbench").setup({
    keymaps = {
        preset = "recommended",
        prefix = "<Leader>a", -- optional; this is the default prefix
    },
})
```

| Key | Modes | Action |
| --- | --- | --- |
| `<Leader>aa` | Normal | Create and activate a new independent session buffer |
| `<Leader>ac` | Normal | Continue the latest session |
| `<Leader>ar` | Normal | Resume a past session |
| `<Leader>am` | Normal, Visual | Mention the current file or visual selection |
| `<Leader>ad` | Normal | Review the current session diff |
| `<Leader>at` | Normal | Open the next attention request |
| `<Leader>aw` | Normal | Pick and switch workspace |
| `<Leader>aW` | Normal | Create a workspace after choosing its directory |
| `<Leader>ae` | Normal | Toggle the workspace explorer sidebar |
| `<M-h>` | Normal | Switch to the previous listed buffer in the workspace |
| `<M-l>` | Normal | Switch to the next listed buffer in the workspace |
| `<M-j>` | Normal | Switch to the next workspace |
| `<M-k>` | Normal | Switch to the previous workspace |

Set `prefix` to another non-empty key sequence to move the `<Leader>` mappings; the four fixed Alt navigation mappings do not use the prefix. Existing global mappings are never overwritten: Agent Workbench skips each colliding mode/key pair and emits one warning listing the skipped mappings. Set `preset = false` (the default) to remove mappings previously installed by the preset without deleting user replacements.

The preset is installed by `setup()`, so it does not itself act as a lazy.nvim key-trigger. Users who want key-triggered lazy loading should declare equivalent mappings in lazy.nvim's `keys` field instead.

What the plugin binds inside its own buffers:

- Submission keys in the prompt buffer (`<CR>`, `<A-CR>`, `<S-CR>` — see [Usage → Prompt](usage.md#prompt)).
- `<Esc>` / double-`<Esc>` abort gestures (see [Usage → Aborting](usage.md#aborting-with-double-esc)).
- `<C-p>` / `<C-n>` / `<Up>` / `<Down>` prompt-history recall (see [Usage → Prompt history](usage.md#prompt-history)).
- Shell worksheet: `<CR>` runs the current input cell in Normal or Insert mode; Insert `<S-CR>` adds a newline; Normal edit keys `i` / `I` / `a` / `A` / `o` / `O` / `c` / `C` jump from completed commands or output to the current input and enter Insert mode; `<C-d>` returns to compose from an empty current input while retaining native Vim behavior elsewhere; Normal `<C-c>` interrupts only while a command runs; `<C-g>c` interrupts from Normal or Insert mode; worksheet `q` or `<C-g>p` returns to compose; terminal-float Normal `q` interrupts the foreground program and closes the float, while terminal `<C-g>p` closes only the float; `<C-g>t` reopens worksheet. With blink.cmp, completion uses the user's existing Blink keymaps without worksheet overrides. The no-Blink fallback owns Insert `<Tab>` / `<S-Tab>`. Compose-only prompt mappings are removed while the worksheet is active, and colliding buffer-local mappings are restored on exit (see [Usage → Shell worksheet](usage.md#shell-worksheet-)).
- Prompt request mode uses `j`/`k`/`↑`/`↓` to select, `<CR>` to confirm, and `<C-c>` to cancel; `<Esc>` never dismisses request (see [Attention → Prompt request mode](attention.md#prompt-request-mode)).
- `<Tab>` opens complete long tool output in a viewer (and toggles short output inline); `za` / `<CR>` / `o` toggle block previews, while `gf` opens the file under the cursor in the history buffer.
- `dd` / `x` to remove an entry in the attachments buffer.
- The [diff review](diff-review.md) keys inside the diff tab.
- The `:AgentWorkbenchDiff` session diff review: in the panel's file list, moving the cursor previews the file's diff, `<CR>`/`o` jumps to its first changed line, `<C-f>`/`<C-b>`/`<C-d>`/`<C-u>` scroll the diff on the right; in the diff area, `<CR>`/`o` jumps to the line under the cursor; `q` closes the whole review (see [Session diff review](diff-review.md#session-diff-review-agentworkbenchdiff)).
- The [sessions overview](sessions.md#sessions-overview-agentworkbenchsessions) keys inside the list.
- The workspace sidebar uses tree-style keys: on workspace rows, both `h` and `l` toggle expansion; persisted sessions appear under `Today`, `Yesterday`, `Last 7 days`, and `Older`, with only `Today` expanded by default. On time-group rows, `l` / `<CR>` / `e` / `<Tab>` toggle expansion and `h` collapses toward the workspace. On historical-session rows, `<CR>` / `l` resumes in that workspace, reusing an already-open session or creating a separate live one. On open-session rows, `h` collapses the parent, `l` activates, and `p` previews live History without switching workspace; on buffer rows, `<CR>` / `l` switches to that buffer. `d` closes/stops/deletes only workspace, open-session, and buffer rows; historical files remain untouched. The last workspace cannot be closed. `a` creates a session, `A` creates a workspace, `o` switches and closes, `R` reloads historical metadata and live state, `?` shows help, and `q` closes.

## Key specs

Several config fields (`diff.keys`, `dialog.keys`, `zen.keys`) accept a **key spec** instead of a plain string, so you can pin mappings to specific modes and bind multiple keys to the same action. A key spec is one of:

```lua
-- 1. A plain string — single mapping in the default modes for that field.
accept = "<Leader>da"

-- 2. A table with `.modes` — single mapping in the given modes.
accept = { "<C-CR>", modes = { "n", "i", "v" } }

-- 3. A list of the above — multiple keys bound to the same action.
accept = {
    "<Leader>da",
    { "<C-CR>", modes = { "n", "i", "v" } },
}
```

All three forms are accepted anywhere a key spec is expected. A table is interpreted as a single spec when it has a `.modes` field, and as a list of specs otherwise.

## Stable filetypes

Every π buffer gets a stable filetype, so you can target them from your own `FileType` autocmds:

| Filetype | Buffer |
| --- | --- |
| `pi-chat-history` | Chat history panel |
| `pi-chat-prompt` | Prompt panel |
| `pi-chat-attachments` | Attachments panel |
| `pi-tool-output` | Read-only split for tool output longer than 30 lines |
| `pi-dialog` | Input and info dialog floats (completion plugins can be disabled here without affecting the prompt) |
| `pi-sessions` | The [sessions overview](sessions.md#sessions-overview-agentworkbenchsessions) list |
| `pi-workspaces` | The collapsible workspace explorer sidebar |
| `pi-diff-review` | The `:AgentWorkbenchDiff` session diff review file list (left area of the panel) |

## Custom buffer-local setup

The preset only adds global entry points. Use the stable filetypes and public Lua interface for additional buffer-local mappings. The `<S-Up>` / `<S-Down>` mappings below are placeholders — replace them with whatever keys you already use to move between windows in the rest of Neovim. Focus navigation inside Agent Workbench should match your normal window navigation rather than introduce another convention.

```lua
local pi = require("agent-workbench")

-- Buffer-local mappings inside π windows.
-- Filetypes: "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments".
local group = vim.api.nvim_create_augroup("pi-keymaps", { clear = true })

local function map(buf, key, action, modes)
    vim.keymap.set(modes or { "n", "i", "v" }, key, action, { buffer = buf })
end

-- Shared across all π windows.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments" },
    callback = function(event)
        map(event.buf, "<C-q>", "<Cmd>AgentWorkbenchToggleChat<CR>")
        map(event.buf, "<M-c>", "<Cmd>AgentWorkbenchAbort<CR>")
        map(event.buf, "<C-o>", pi.toggle_history_blocks)
    end,
})

-- History window: jump to prompt.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-history",
    callback = function(event)
        map(event.buf, "<S-Down>", pi.focus_chat_prompt)
    end,
})

-- Prompt window: navigation, scrolling, model & thinking, sessions, attachments.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-prompt",
    callback = function(event)
        -- focus
        map(event.buf, "<S-Up>",   pi.focus_chat_history)
        map(event.buf, "<S-Down>", pi.focus_chat_attachments)
        -- scroll history from the prompt
        map(event.buf, "<C-Up>",   function() pi.scroll_chat_history("up", 2) end)
        map(event.buf, "<C-Down>", function() pi.scroll_chat_history("down", 2) end)
        -- model & thinking
        map(event.buf, "<M-m>", pi.cycle_model)
        map(event.buf, "<M-M>", pi.select_model)
        map(event.buf, "<M-t>", pi.cycle_thinking_level)
        map(event.buf, "<M-T>", pi.select_thinking_level)
        -- sessions & context
        map(event.buf, "<M-n>", pi.new_session)
        map(event.buf, "<M-x>", pi.compact)
        -- attachments
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})

-- Attachments window: jump back to prompt, paste image.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-attachments",
    callback = function(event)
        map(event.buf, "<S-Up>", pi.focus_chat_prompt)
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})
```
