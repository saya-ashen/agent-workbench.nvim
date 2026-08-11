# Lua API

Everything exposed by the [user commands](../README.md#commands) is also available from Lua. Grab the module once and call into it directly:

```lua
local pi = require("pi")

-- Setup (called once from your config entrypoint)
pi.setup(opts?)

-- Chat lifecycle
pi.show(opts?)                -- open the chat; opts: { layout = "side"|"float" }
pi.toggle(opts?)              -- open or hide the chat
pi.toggle_chat()              -- hide/show the chat windows for the current tab
pi.toggle_layout(cb?)         -- swap buffer ↔ float; cb runs after swap completes
pi.is_visible()               -- boolean: is the chat shown in the current tab?
pi.layout()                   -- "side" | "float" | nil

-- Sessions
pi.continue_session(opts?)    -- load the most recent session for the current cwd
pi.resume_session(opts?)      -- pick a past session for the current cwd
pi.new_session()              -- start a fresh conversation in the current tab
pi.tree()                     -- navigate the session tree (:PiTree)
pi.sessions()                 -- toggle the live sessions overview (:PiSessions)
pi.set_session_name(name?)    -- set the session display name; without an arg, opens an
                              -- input dialog prefilled with the current name
pi.compact(instructions?)     -- manually compact the current session (optional guidance)
pi.changed_files()            -- string[]: files modified by edit/write tools this session

-- Agent control
pi.abort()                    -- cancel the current agent turn, keep the session alive
pi.abort_bash()               -- cancel the running direct bash (!) command
pi.stop()                     -- kill the RPC process and close the chat for the current tab

-- Prompt input
pi.send_mention(args?, opts?) -- insert an @-mention for the current buffer / selection
pi.attach_image(path)         -- queue an image file as an attachment
pi.paste_image()              -- queue an image from the clipboard (requires img-clip.nvim)
pi.invoke("/command")         -- invoke a backend slash command programmatically

-- Models
pi.cycle_model()              -- step to the next model in the configured (or all) list
pi.select_model()             -- dialog: pick from configured models (or all when no list is set)
pi.select_model_all()         -- dialog: pick from every backend-available model

-- Thinking
pi.toggle_thinking()          -- show/hide thinking blocks in the history
pi.cycle_thinking_level()     -- step to the next thinking level
pi.select_thinking_level()    -- dialog: pick a thinking level

-- History blocks
pi.toggle_startup_details()   -- collapse/expand the startup block
pi.toggle_history_blocks()    -- collapse/expand all expandable history blocks

-- Attention queue
pi.attention()                -- open the oldest queued request, switching tab if needed
pi.attention_count(tab?)      -- integer: pending requests in a tab (current tab if omitted)
pi.attention_total()          -- integer: pending requests across all tabs
pi.attention_state(tab?)      -- full state snapshot for custom UI
pi.has_attention(tab?)        -- boolean shortcut for attention_count > 0

-- Navigation inside the chat
pi.focus_chat_history()
pi.focus_chat_prompt()
pi.focus_chat_attachments()
pi.scroll_chat_history(direction, lines?)          -- direction: "up" | "down"; lines defaults to 15
pi.scroll_chat_history_to_bottom()
pi.scroll_chat_history_to_first_agent_response()
pi.scroll_chat_history_to_last_agent_response()
pi.goto_file_under_cursor()   -- open the file referenced on the history line under the cursor

-- Debug
pi.toggle_debug()             -- toggle RPC debug logging for the current Neovim session
```

Most functions are no-ops (or warn) when no session is active in the current tab — safe to bind unconditionally. See [Usage](usage.md) and [Keymaps](keymaps.md) for how these fit into a working setup.
