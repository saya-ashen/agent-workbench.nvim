# Keymaps

`pi2.nvim` intentionally ships with a very small default keymap set. Keymaps tend to be highly personal, and many users already have their own conventions, leader-based layouts, or other mapping systems. Pi tries to provide the API and a few sensible defaults, while leaving the final keymap design to you.

What the plugin does bind on its own:

- Submission keys in the prompt buffer (`<CR>`, `<A-CR>`, `<S-CR>` — see [Usage → Prompt](usage.md#prompt)).
- `<Esc>` / double-`<Esc>` abort gestures (see [Usage → Aborting](usage.md#aborting-with-double-esc)).
- `<C-p>` / `<C-n>` / `<Up>` / `<Down>` prompt-history recall (see [Usage → Prompt history](usage.md#prompt-history)).
- `<Tab>` block expand/collapse and `gf` open-file-under-cursor in the history buffer.
- `dd` / `x` to remove an entry in the attachments buffer.
- The [diff review](diff-review.md) keys inside the diff tab.
- The `:PiDiff` session diff review: in the panel's file list, moving the cursor previews the file's diff, `<CR>`/`o` jumps to its first changed line, `<C-f>`/`<C-b>`/`<C-d>`/`<C-u>` scroll the diff on the right; in the diff area, `<CR>`/`o` jumps to the line under the cursor; `q` closes the whole review (see [Session diff review](diff-review.md#session-diff-review-pidiff)).
- The [sessions overview](sessions.md#sessions-overview-pisessions) keys inside the list.

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
| `pi-dialog` | Input and info dialog floats (completion plugins can be disabled here without affecting the prompt) |
| `pi-sessions` | The [sessions overview](sessions.md#sessions-overview-pisessions) list |
| `pi-diff-review` | The `:PiDiff` session diff review file list (left area of the panel) |

## Example setup

A reasonable starting point looks like this:

```lua
local pi = require("pi")

-- Global mappings — open / toggle / resume from anywhere.
vim.keymap.set({ "n", "v" }, "<Leader>pp", function() vim.cmd("Pi layout=side")  end, { desc = "Pi side"  })
vim.keymap.set({ "n", "v" }, "<Leader>pf", function() vim.cmd("Pi layout=float") end, { desc = "Pi float" })
vim.keymap.set({ "n", "v" }, "<Leader>pl", "<Cmd>PiToggleLayout<CR>",                 { desc = "Pi toggle layout" })
vim.keymap.set({ "n", "v" }, "<Leader>pc", "<Cmd>PiContinue<CR>",                     { desc = "Pi continue last session" })
vim.keymap.set({ "n", "v" }, "<Leader>pr", "<Cmd>PiResume<CR>",                       { desc = "Pi resume past session" })
vim.keymap.set({ "n", "v" }, "<Leader>pm", "<Cmd>PiSendMention<CR>",                  { desc = "Pi mention file/selection" })
vim.keymap.set({ "n", "v" }, "<Leader>pa", "<Cmd>PiAttention<CR>",                    { desc = "Pi open next attention request" })
```

The `<S-Up>` / `<S-Down>` mappings below are sort of placeholders — replace them with whatever keys you already use to move between windows in the rest of Neovim. The idea is that focus navigation inside π windows should match your normal buffer/window navigation, not introduce new conventions.

```lua
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
        map(event.buf, "<C-q>", "<Cmd>PiToggleChat<CR>")
        map(event.buf, "<M-c>", "<Cmd>PiAbort<CR>")
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
