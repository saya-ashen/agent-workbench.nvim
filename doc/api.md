# Lua API

Everything exposed by the [user commands](../README.md#commands) is also available from Lua. Grab the module once and call into it directly:

```lua
local pi = require("agent-workbench")

-- Backend registration (external backend plugins call before setup)
pi.register_backend(name, factory) -- factory(options) -> BackendSession

-- Setup (called once from your config entrypoint; Pi is the default backend)
pi.setup(opts?)

-- Chat lifecycle
pi.show(opts?)                -- open the chat; opts: { layout = "side"|"float" }
pi.toggle(opts?)              -- open or hide the chat
pi.toggle_chat()              -- hide/show the chat windows for the current tab
pi.toggle_layout(cb?)         -- swap buffer ↔ float; cb runs after swap completes
pi.is_visible()               -- boolean: is the chat shown in the current tab?
pi.layout()                   -- "side" | "float" | nil

-- Sessions
pi.continue_session(opts?)    -- load the newest history item from the active backend
pi.resume_session(opts?)      -- pick and load backend history (Pi uses cwd-scoped JSONL)
pi.new_session()              -- create and activate a separate session buffer
pi.replace_session()          -- replace current idle session and delete its live History buffer
pi.tree()                     -- navigate the session tree (:AgentWorkbenchTree)
pi.sessions()                 -- toggle the live sessions overview (:AgentWorkbenchSessions)
pi.workspaces()               -- pick and switch a tab-backed workspace (:AgentWorkbenchWorkspaces)
pi.workspace_sidebar()        -- toggle the collapsible workspace explorer (:AgentWorkbenchWorkspaceSidebar)
pi.new_workspace()            -- select a directory and create a workspace (:AgentWorkbenchNewWorkspace)
pi.workspace_list()           -- workspace rows in tabline order
pi.workspace_tabline()        -- built-in tabline rendering for integrations
pi.move_buffer(tab_number)    -- move current ordinary buffer to another workspace
pi.session_stats()            -- show the session stats dashboard (:AgentWorkbenchSessionStats)
pi.diff_review()              -- review the git diff of every file changed this session (:AgentWorkbenchDiff)
pi.set_session_name(name?)    -- set the session display name; without an arg, opens an
                              -- input dialog prefilled with the current name
pi.compact(instructions?)     -- manually compact the current session (optional guidance)
pi.toggle_auto_compaction()   -- flip automatic compaction on/off; the statusline
                              -- `compaction` component (a 󰏗 icon) shows the state
pi.changed_files()            -- string[]: files modified by edit/write tools this session

-- Agent control
pi.abort()                    -- cancel the current agent turn, keep the session alive
pi.focus_terminal()           -- reopen persistent shell worksheet after `!!` starts it
pi.abort_bash()               -- cancel the running direct bash (!) command
pi.abort_retry()              -- cancel the auto-retry backoff ("Retrying…" state); only
                              -- takes effect while the core is between retry attempts
pi.stop()                     -- stop current session and delete its History buffer

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

Most functions are no-ops (or warn) when no session is active in the current buffer/tab — safe to bind unconditionally. See [Usage](usage.md) and [Keymaps](keymaps.md) for how these fit into a working setup.
