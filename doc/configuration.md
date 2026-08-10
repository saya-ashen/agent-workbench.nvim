# Configuration

All options are optional — `require("pi").setup()` with no arguments gives you the defaults below. This page is the full reference; the [README](../README.md) has a shorter overview of the most common knobs.

```lua
---@type pi.Options
require("pi").setup({
    -- pi CLI invocation. Extra args are inserted before `--mode rpc`.
    -- Args that conflict with RPC mode (`--mode`, `--print`, `--help`, etc.)
    -- are dropped with a one-time warning.
    cli = {
        bin = "pi",
        args = {},
    },
    -- Optional protocol adapter hooks for non-upstream-compatible RPC backends.
    -- See doc/extensions.md, "Adapting non-upstream RPC backends".
    rpc = {
        map_command = nil, -- fun(cmd, ctx): cmd|nil
        map_event = nil, -- fun(msg, ctx): msg|nil
    },
    -- Enable RPC debug logging to `stdpath("log")/pi/<session>/rpc.log`.
    debug = false,
    -- Override the π agent directory used for session lookup.
    -- Defaults to $PI_CODING_AGENT_DIR or ~/.pi/agent.
    agent_dir = nil,
    -- Preferred models for cycling and the :PiSelectModel picker.
    -- Each entry is either a string (exact ID) or a table:
    --   { match = "opus", latest = true }
    --   { match = "gpt-5.3-codex", exact = true } or just "gpt-5.3-codex"
    models = nil,
    -- Spinner shown while the agent is working.
    -- Preset name ("classic"|"robot"), array of frames (strings), or
    -- { refresh_rate = ms, frames = { ... } }.
    spinner = "robot",
    -- Show thinking blocks by default.
    show_thinking = true,
    -- Extra blank line between conversation turns (pure whitespace, no drawn rule).
    turn_separator = true,
    -- Default expand/collapse state for the startup block
    -- (skills, extensions, startup announcements).
    expand_startup_details = true,
    -- Format string passed to os.date for chat message timestamps.
    timestamp_format = Os.is_windows() and "%b %#d %Y, %H:%M" or "%b %-d %Y, %H:%M",

    -- Chat panels
    panels = {
        history = { title = "π" },
        prompt = { title = "prompt", bash_title = "bash" },
        attachments = { title = "attached" },
    },

    -- Inline labels rendered in the chat history. `tool` is the fallback icon;
    -- common tools (bash, read, edit, write, grep, …) use a built-in per-tool
    -- Nerd Font icon and ignore this value.
    labels = {
        user_message = "",
        agent_response = "󰚩",
        system_error = "󱚟",
        tool = "󰻂",
        tool_success = "",
        tool_failure = "",
        steer_message = "󰾘",
        follow_up_message = "󱇼",
        thinking = "󰟶",
        compaction = "󰏗",
        attachment = "",
        attachments = "",
        error = "",
    },

    -- Chat layout
    layout = {
        -- Default layout when opening the chat: "side" or "float".
        default = "side",
        side = {
            -- Side panel position: "left", "right", or "bottom".
            position = "right",
            -- Width in columns when position is "left" or "right".
            width = 80,
            panels = {
                -- Show winbars on each panel in side layout.
                history = { winbar = true },
                prompt = { winbar = true },
                attachments = { winbar = true },
            },
        },
        float = {
            -- Width/height: fraction (<1) or columns/lines (>=1).
            width = 0.6,
            height = 0.8,
            border = "rounded",
        },
    },

    -- Status line in the prompt window
    statusline = {
        -- Components rendered in the prompt statusline.
        -- Entries are built-in component names, literal separators,
        -- or custom component functions.
        layout = {
            left = { "context", "  ", "attention", "  ", "queue" },
            -- Centered group; has placement priority over left/right.
            center = { "spinner" },
            right = { "model", "   ", "thinking" },
        },
        components = {
            tokens = { icon = "" },
            cache = { icon = "󰆼" },
            cost = { icon = "" },
            compaction = { icon = false },
            context = { icon = "", warn = 70, error = 90 },
            attention = { icon = "󰵚", counter = false },
            model = { icon = "󰚩" },
            thinking = { icon = "󰟶" },
            queue = { icon = "⏵" },
        },
    },

    -- Diff review
    diff = {
        icons = {
            -- Icon/sign used for diff review notes. Set to false to omit it.
            note = "󰆈",
        },
        -- Visible context around each hunk.
        context = {
            -- Initial visible context around each hunk.
            -- nil means use current 'diffopt' context.
            base = nil,
            -- Lines added/removed by expand/shrink actions.
            step = 5,
        },
        -- How to show diff review keymap hints:
        -- "dialog" or true (default): show compact "?=keymaps" and open an informational keymap dialog with ?.
        -- "winbar": show full inline winbar hints.
        -- false: hide hints and bind no help key.
        keymap_hints = "dialog",
        -- Keymaps active inside the diff review tab.
        keys = {
            accept = "<Leader>da",
            reject = "<Leader>dr",
            edit_note = "<Leader>dn",
            delete_note = "<Leader>dx",
            list_notes = "<Leader>dN",
            expand_context = "<Leader>de",
            shrink_context = "<Leader>ds",
        },
    },

    -- Attention queue for user-input requests (confirms, selects, etc.)
    attention = {
        -- Auto-open the next pending attention request when the
        -- current tab's prompt is refocused and empty.
        -- If false, needs :PiAttention command to pull what's pending.
        auto_open_on_prompt_focus = true,
        -- Notify when the agent finishes a turn and the prompt is not focused.
        notify_on_completion = true,
    },

    -- Buffer reload: what to do when pi modifies a file that is open in a buffer.
    reload = {
        -- "silent" : reload unmodified buffers silently; skip modified ones (default)
        -- "notify" : same as silent, plus a notification listing reloaded/skipped files
        -- false    : disabled — buffers are never touched
        mode = "silent",
    },

    -- Load search-tool results into the quickfix list (never auto-opened; use :copen).
    quickfix = {
        grep = true, -- grep matches (path:line[:col]: text)
        find = false, -- find file list (one path per line)
        glob = false, -- alias of `find` for older pi versions that named the tool `glob`
    },

    -- Double-<Esc> aborts the running agent (same as :PiAbort).
    abort = {
        -- Enable the double-<Esc> abort gesture.
        enabled = true,
        -- Window in ms for the second <Esc> to count.
        timeout = 1500,
        -- Hint echoed (after the "π │ " prefix) on the first <Esc>.
        message = "Press <Esc> again to abort",
    },

    -- Session tree navigation (:PiTree). Injects the bundled pi extension
    -- (extensions/tree.ts) into every RPC process; requires a pi version
    -- whose extension API exposes ctx.navigateTree.
    tree = {
        enabled = true,
    },

    -- Sessions overview (:PiSessions): a live list of all active sessions
    -- (one per tab) — a status dot whose color/animation encodes the state
    -- (busy/compacting/attention/done/error/idle/exited) plus the session
    -- name. See doc/sessions.md for details.
    sessions_list = {
        -- How the window opens: "side" | "float" explicitly, or "follow" the
        -- current tab's chat layout (default).
        mode = "follow",
        -- Open the list together with the chat (:Pi etc.).
        auto_open = false,
        -- Window placement in the side layout: "left" | "right" | "top" | "bottom".
        position = "left",
        -- Window width for left/right placement (side layout).
        width = 40,
        -- Window height for top/bottom placement (side layout).
        height = 12,
        -- Float sizing when the current tab uses the float layout.
        float = {
            width = 0.5, -- fraction (<1) of editor width, or columns (>=1)
            height = 0.4, -- fraction (<1) of editor height, or lines (>=1)
            border = "rounded",
        },
    },

    -- Select/confirm pickers render through vim.ui.select; this styles the
    -- input/info dialog floats.
    dialog = {
        border = "rounded",
        -- Max size: fraction (<1) or columns/lines (>=1).
        max_width = 0.8,
        max_height = 0.8,
        keys = {
            -- Optional dialog keymaps; nil leaves built-in defaults in place.
            confirm = nil,
            cancel = nil,
        },
    },

    -- Zen mode for composing larger prompts
    zen = {
        -- Prompt width in columns. nil = textwidth if set, otherwise 80.
        width = nil,
        keys = {
            -- Key to enter/exit zen mode.
            toggle = nil,
            -- Additional keys that only exit zen mode.
            exit = nil,
        },
    },

    -- Prompt buffer behavior.
    prompt = {
        -- Readline-style recall of previously submitted prompts.
        history = {
            -- Record submissions and allow recalling them with
            -- <C-p>/<C-n> and <Up>/<Down>.
            enabled = true,
            -- Maximum entries kept; oldest are dropped first.
            max = 500,
            -- History file. nil = stdpath("data")/pi/prompt_history.json.
            path = nil,
        },
        -- Unsent-draft persistence across restarts.
        draft = {
            enabled = true,
        },
        -- Intercept paste in the prompt: when the system clipboard holds an
        -- image, attach it (like :PiPasteImage) instead of inserting text.
        -- Requires img-clip.nvim; plain-text pastes are never affected.
        paste_image = true,
        -- Compress image attachments before sending (external tool required:
        -- sips on macOS, ImageMagick magick, or ffmpeg; without one the
        -- original image is attached silently).
        image_compress = {
            -- Master switch.
            enable = true,
            -- Longest side in pixels; larger images are downscaled. 0 = no resize.
            max_dimension = 1568,
            -- jpeg/webp quality 0-100 (PNG is lossless and ignores this).
            quality = 80,
            -- "keep" (input format), "jpeg", "png", or "webp" (webp degrades
            -- to "keep" when only sips is available).
            format = "keep",
            -- "auto" (probe sips → magick → ffmpeg) or a tool name.
            tool = "auto",
            -- "all" = also compress dropped/attached files; "clipboard" = only
            -- clipboard pastes. svg and gif are never touched.
            scope = "all",
        },
    },

    -- Markdown rendering of the chat history.
    render = {
        -- "render-markdown" (default, delegates to render-markdown.nvim)
        -- or "builtin" (treesitter + custom drawing).
        engine = "render-markdown",
    },

    -- Verb pairs for status messages, picked randomly per run.
    verbs = {
        -- When true, user pairs are appended to the built-in list;
        -- when false, they replace it.
        use_defaults = true,
        pairs = {
            { "Rewriting in Rust", "Rewrote in Rust" },
            { "Making no mistakes", "Made no mistakes" },
            -- ... and more built-in pairs
        },
    },

    -- Extension setWidget hook. Return a custom block to render inline
    -- in history, or nil to ignore. Not called for `:startup` widgets.
    on_widget = nil,

    -- Custom dynamic @-mention providers (see doc/usage.md, "Dynamic mentions").
    -- name -> function returning context text, or a spec table
    -- { fn = ..., description = ..., lang = ... }.
    mention_providers = {},
})
```

Notes on a few fields:

- `layout.default`, `layout.side`, and `layout.float` each also accept a **function** returning the value, so you can compute sizes from `vim.o.columns` / `vim.o.lines` at open time. A function-return for `side`/`float` is deep-merged over the defaults, so returning a partial table is fine.
- `panels.<panel>.name` takes a `fun(tab_id): string` that computes the underlying buffer name per tab — useful for distinguishing multiple π conversations in `:buffers`, statuslines, or tab bars.
- Several fields (`diff.keys`, `dialog.keys`, `zen.keys`) accept **key specs** — plain strings, `{ key, modes = ... }` tables, or lists of those. See [Keymaps](keymaps.md#key-specs).

## Project trust

`pi2.nvim` runs pi in RPC mode and does not currently implement the TUI's interactive project trust prompt or save trust decisions. It uses pi's non-interactive defaults, which means project-local settings, resources, packages, extensions, and project `.agents/skills` are not loaded.

To trust project-local pi files when using `pi2.nvim`, either pass pi's trust flag through `cli.args`:

```lua
require("pi").setup({
    cli = {
        args = { "--approve" },
    },
})
```

or set the global pi default in `~/.pi/agent/settings.json`:

```json
{
  "defaultProjectTrust": "always"
}
```

If you need interactive trust handling in `pi2.nvim`, please open an issue.
