---@class agent_workbench.PanelOpts
---@field title string
---@field bash_title? string Title shown when the prompt is in bash mode (prompt panel only, default: "bash")
---@field name? fun(tab: agent_workbench.TabId): string

---@class agent_workbench.Panels
---@field history agent_workbench.PanelOpts
---@field prompt agent_workbench.PanelOpts
---@field attachments agent_workbench.PanelOpts

---@class agent_workbench.SidePanelOpts
---@field winbar boolean

---@class agent_workbench.SidePanels
---@field history agent_workbench.SidePanelOpts
---@field prompt agent_workbench.SidePanelOpts
---@field attachments agent_workbench.SidePanelOpts

---@class agent_workbench.SideLayout
---@field position "left"|"right"|"bottom"
---@field width integer
---@field height? integer
---@field panels agent_workbench.SidePanels

---@class agent_workbench.FloatLayout
---@field width number width in columns (>=1) or fraction of screen (<1)
---@field height number height in lines (>=1) or fraction of screen (<1)
---@field border string|string[]
---@field win? vim.api.keyset.win_config Extra options passed to nvim_open_win

---@alias agent_workbench.LayoutMode "buffer"|"side"|"float"

---@class agent_workbench.LayoutConfig
---@field default agent_workbench.LayoutMode|fun(): agent_workbench.LayoutMode
---@field side agent_workbench.SideLayout|fun(): agent_workbench.SideLayout
---@field float agent_workbench.FloatLayout|fun(): agent_workbench.FloatLayout

---@class agent_workbench.ZenKeys
---@field toggle? agent_workbench.KeySpecs Key(s) to enter/exit zen mode
---@field exit? agent_workbench.KeySpecs Additional key(s) that only exit zen mode

---@class agent_workbench.ZenConfig
---@field width? integer Prompt width in columns (default: textwidth if set, otherwise 80)
---@field keys agent_workbench.ZenKeys

---@class agent_workbench.PromptHistoryConfig
---@field enabled? boolean Record submitted prompts and allow recalling them (default: true)
---@field max? integer Maximum number of entries kept (oldest dropped, default: 500)
---@field path? string Override the history file (default: stdpath("data")/pi/prompt_history.json)

---@class agent_workbench.PromptConfig
---@field history agent_workbench.PromptHistoryConfig
---@field draft agent_workbench.PromptDraftConfig
---@field paste_image? boolean Intercept paste in the prompt: when the clipboard holds an image, attach it instead of inserting text (default: true, requires img-clip.nvim)
---@field image_compress agent_workbench.ImageCompressConfig

---@class agent_workbench.ImageCompressConfig
---@field enable? boolean Compress image attachments before sending (default: true; silently falls back to the original when no tool is available)
---@field max_dimension? integer Longest side in pixels; images larger than this are downscaled (default: 1568, 0 = no resize)
---@field quality? integer jpeg/webp quality 0-100 (default: 80; PNG is lossless and ignores this)
---@field format? "keep"|"jpeg"|"png"|"webp" Output format (default: "keep"; "webp" degrades to "keep" when only sips is available)
---@field tool? "auto"|"sips"|"magick"|"ffmpeg" Compression tool (default: "auto", probes sips → magick → ffmpeg)
---@field scope? "clipboard"|"all" Which attachments to compress: only clipboard pastes, or also dropped/attached files (default: "all")

---@class agent_workbench.PromptDraftConfig
---@field enabled? boolean Persist unsent prompts per workspace and restore stale drafts after restart (default: true)

---@class agent_workbench.RenderConfig
---@field engine? string Markdown renderer for chat history: "markview" (default), "render-markdown", or "builtin"

---@class agent_workbench.DiffKeys
---@field accept agent_workbench.KeySpecs
---@field reject agent_workbench.KeySpecs
---@field edit_note agent_workbench.KeySpecs
---@field delete_note agent_workbench.KeySpecs
---@field list_notes agent_workbench.KeySpecs
---@field expand_context agent_workbench.KeySpecs
---@field shrink_context agent_workbench.KeySpecs

---@class agent_workbench.DiffContextConfig
---@field base? integer
---@field step integer

---@class agent_workbench.DiffIcons
---@field note string|false Icon/sign used for diff review notes. Set false to omit the icon/sign.

---@class agent_workbench.DiffConfig
---@field icons agent_workbench.DiffIcons
---@field context agent_workbench.DiffContextConfig
---@field keymap_hints? "dialog"|"winbar"|boolean
---@field keys agent_workbench.DiffKeys

---@alias agent_workbench.SpinnerPreset "classic"|"robot"

---@alias agent_workbench.VerbPair [string, string] [0]=active (e.g. "Cooking"), [1]=done (e.g. "Cooked")

---@class agent_workbench.VerbsConfig
---@field use_defaults? boolean When true (default), user pairs are appended to the built-in list; when false, they replace it
---@field pairs? agent_workbench.VerbPair[] Verb pairs

---@class agent_workbench.Labels
---@field user_message string
---@field agent_response string
---@field system_error string
---@field tool string
---@field tool_success string
---@field tool_failure string
---@field steer_message string
---@field follow_up_message string
---@field thinking string
---@field compaction string
---@field attachment string
---@field attachments string
---@field error string

---@alias agent_workbench.StatusLineItem string|agent_workbench.StatusLineComponentFn

---@alias agent_workbench.StatusLineBuiltinName
---| "tokens"
---| "cache"
---| "cost"
---| "compaction"
---| "context"
---| "attention"
---| "model"
---| "thinking"
---| "queue"
---| "spinner"

---@class agent_workbench.StatusLineLayout
---@field left agent_workbench.StatusLineItem[] Built-in names, literal separators, or custom components
---@field center? agent_workbench.StatusLineItem[] Built-in names, literal separators, or custom components
---@field right agent_workbench.StatusLineItem[] Built-in names, literal separators, or custom components

---@class agent_workbench.StatusLineComponentConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.

---@class agent_workbench.StatusLineContextConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field warn? number Percentage threshold for warning highlight (default 70)
---@field error? number Percentage threshold for error highlight (default 90)

---@class agent_workbench.StatusLineCostConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field warn? number Optional cost threshold for warning highlight
---@field error? number Optional cost threshold for error highlight

---@class agent_workbench.StatusLineAttentionConfig
---@field icon? string|false Prefix icon rendered before the component text. Use false to disable.
---@field counter? boolean Show the pending attention count next to the icon.

---@class agent_workbench.StatusLineComponents
---@field tokens? agent_workbench.StatusLineComponentConfig
---@field cache? agent_workbench.StatusLineComponentConfig
---@field cost? agent_workbench.StatusLineCostConfig
---@field compaction? agent_workbench.StatusLineComponentConfig
---@field context? agent_workbench.StatusLineContextConfig
---@field attention? agent_workbench.StatusLineAttentionConfig
---@field model? agent_workbench.StatusLineComponentConfig
---@field thinking? agent_workbench.StatusLineComponentConfig
---@field queue? agent_workbench.StatusLineComponentConfig

---@class agent_workbench.StatusLineConfig
---@field enabled? boolean Render statusline virtual rows below prompt (default false)
---@field layout agent_workbench.StatusLineLayout
---@field components? agent_workbench.StatusLineComponents

---@class agent_workbench.UiAttentionConfig
---@field auto_open_on_prompt_focus boolean Automatically open the next pending attention request for the current tab when the prompt gains focus and has no draft.
---@field notify_on_completion boolean Show an info notification when the agent finishes a turn and the prompt does not have focus.

---@class agent_workbench.ReloadConfig
---@field mode? "silent"|"notify"|false How to handle open buffers when pi modifies their file. "silent": reload unmodified buffers silently, skip modified ones. "notify": same as silent but also show a notification listing reloaded and skipped files. false: disabled. Default: "silent"

---@class agent_workbench.QuickfixConfig
---@field grep? boolean Fill the quickfix list from grep tool results (default: true)
---@field find? boolean Fill the quickfix list from find tool results (default: false)
---@field glob? boolean Alias of `find` for older pi versions that named the tool `glob` (default: false)

---@class agent_workbench.AbortConfig
---@field enabled? boolean Enable double-<Esc> to abort the running agent (default: true)
---@field timeout? integer Window in milliseconds for the second <Esc> to count (default: 1500)
---@field message? string Hint shown in the statusline center on the first <Esc> (default: "Press <Esc> again to abort")

---@class agent_workbench.TreeConfig
---@field enabled? boolean Enable :AgentWorkbenchTree session-tree navigation (default: true). Injects the bundled pi extension (extensions/tree.ts) into every RPC process; requires a pi version whose extension API exposes ctx.navigateTree.

---@class agent_workbench.WorkspaceBarConfig
---@field enabled? boolean Enable built-in workspace tabline when no custom tabline exists (default true)
---@field show? "multiple"|"always" Show only with multiple tabs or always (default "multiple")
---@field label? "name"|"path"|fun(workspace: agent_workbench.WorkspaceRow): string Workspace label (default "name")
---@field show_index? boolean Show visible workspace index (default false)
---@field session_count? boolean Show live session count per workspace (default true)
---@field status? boolean Show aggregated busy/attention status (default true)

---@class agent_workbench.WorkspaceBuffersConfig
---@field enabled? boolean Track buffer ownership and list only current workspace buffers (default true)

---@class agent_workbench.WorkspaceSidebarConfig
---@field position? "left"|"right" Sidebar placement (default "right")
---@field width? integer Sidebar width in columns (default 38)

---@class agent_workbench.SessionsListFloatConfig
---@field width? number Width in columns (>=1) or fraction of editor width (<1, default 0.5)
---@field height? number Height in lines (>=1) or fraction of editor height (<1, default 0.4)
---@field border? string|string[] Float border style (default "rounded")

---@class agent_workbench.SessionsListConfig
---@field mode? "follow"|"side"|"float" How the list window opens: "side" or "float" explicitly, or "follow" the current tab's chat layout (default "follow")
---@field auto_open? boolean Open the list together with the chat (default false)
---@field position? "left"|"right"|"top"|"bottom" Window placement in the side layout (default "left")
---@field width? integer Window width for left/right placement in the side layout (default 40)
---@field height? integer Window height for top/bottom placement in the side layout (default 12)
---@field float agent_workbench.SessionsListFloatConfig Float window sizing when the current tab uses the float layout

---@class agent_workbench.DiffReviewListConfig
---@field position? "left"|"right" Side window placement (default "left")
---@field width? integer Side window width in columns (default 30)

---@class agent_workbench.DiffReviewConfig
---@field width? number Width in columns (>=1) or fraction of editor width (<1, default 0.8)
---@field height? number Height in lines (>=1) or fraction of editor height (<1, default 0.8)
---@field border? string|string[] Float border style (default "rounded")
---@field list agent_workbench.DiffReviewListConfig Side file-list window

---@class agent_workbench.DialogKeys
---@field confirm? agent_workbench.KeySpecs
---@field cancel? agent_workbench.KeySpecs

--- A preferred model entry for cycling/selection.
--- String: exact model ID, or canonical "provider/modelId" reference.
--- Table: substring match with optional latest resolution.
---@alias agent_workbench.ModelEntry string|agent_workbench.ModelSpec

---@class agent_workbench.ModelSpec
---@field match string Substring to match against model IDs (case-insensitive), or exact ID when `exact` is true
---@field exact? boolean If true, `match` is treated as an exact model ID or "provider/modelId" (case-sensitive) instead of a substring
---@field latest? boolean If true, pick the model whose ID sorts last among matches

---@class agent_workbench.DialogConfig
---@field border string|string[]
---@field max_width number max width as fraction of screen (<1) or columns (>=1)
---@field max_height number max height as fraction of screen (<1) or lines (>=1)
---@field keys agent_workbench.DialogKeys

--- A single styled text chunk: { text, hl_group? }.
---@alias agent_workbench.CustomBlockChunk string[]

--- A line of styled chunks.
---@alias agent_workbench.CustomBlockLine agent_workbench.CustomBlockChunk[]

--- Return value from on_widget to render a custom block inline in history.
---@class agent_workbench.CustomBlock
---@field target "history" Where to render the block.
---@field block "custom" Block type.
---@field content agent_workbench.CustomBlockLine[] Lines of styled chunks to render.

--- A custom dynamic @-mention provider (see `mention_providers`).
--- The function returns the context text to attach; nil or empty attaches nothing.
---@alias agent_workbench.MentionProviderFn fun(): string?

---@class agent_workbench.CliConfig
---@field bin string Path to the `pi` executable.
---@field args string[] Extra startup args for every RPC process. agent_workbench.nvim filters args that conflict with RPC mode.

---@class agent_workbench.RpcAdapterContext
---@field set_commands fun(commands: agent_workbench.SlashCommand[]) Replace the shared slash-command cache.

---@class agent_workbench.RpcConfig
---@field map_command? fun(cmd: table, ctx: agent_workbench.RpcAdapterContext): table? Map or drop outbound RPC commands.
---@field map_event? fun(msg: table, ctx: agent_workbench.RpcAdapterContext): table? Map or drop inbound RPC events.

---@class agent_workbench.Options
---@field cli agent_workbench.CliConfig
---@field auto_start_session boolean Create and show a Pi session for every tab-backed workspace on startup and tab entry (default: true)
---@field rpc agent_workbench.RpcConfig
---@field agent_dir? string Override the π agent directory (default: $PI_CODING_AGENT_DIR or ~/.pi/agent)
---@field debug boolean Enable RPC debug logging to stdpath("log")/pi/<session>/rpc.log
---@field models? agent_workbench.ModelEntry[] Preferred models for cycling and :AgentWorkbenchSelectModel
---@field spinner agent_workbench.SpinnerPreset|string[]|{ refresh_rate?: integer, frames: string[] } preset name or custom
---@field show_thinking boolean
---@field turn_separator? boolean Extra blank line between conversation turns (default: true)
---@field expand_startup_details boolean Default expand/collapse state for the startup block (skills, extensions, startup announcements). Always rendered; Tab on the block or API call toggles.
---@field timestamp_format string Format string passed to os.date for chat message timestamps. Defaults to a non-padded day format using the platform-specific os.date flag.
---@field panels agent_workbench.Panels
---@field labels agent_workbench.Labels
---@field layout agent_workbench.LayoutConfig
---@field statusline agent_workbench.StatusLineConfig
---@field diff agent_workbench.DiffConfig
---@field attention agent_workbench.UiAttentionConfig
---@field reload agent_workbench.ReloadConfig
---@field quickfix agent_workbench.QuickfixConfig
---@field abort agent_workbench.AbortConfig
---@field tree agent_workbench.TreeConfig
---@field workspace_bar agent_workbench.WorkspaceBarConfig
---@field workspace_buffers agent_workbench.WorkspaceBuffersConfig
---@field workspace_sidebar agent_workbench.WorkspaceSidebarConfig
---@field sessions_list agent_workbench.SessionsListConfig
---@field diff_review agent_workbench.DiffReviewConfig
---@field zen agent_workbench.ZenConfig
---@field prompt agent_workbench.PromptConfig
---@field render agent_workbench.RenderConfig
---@field dialog agent_workbench.DialogConfig
---@field verbs agent_workbench.VerbsConfig Verb pairs for status messages, picked randomly per run
---@field mention_providers? table<string, agent_workbench.MentionProviderFn|agent_workbench.MentionProviderSpec> Custom dynamic @-mention providers: name → function returning context text (or a spec table with fn/description/lang). Mentioning `@name` attaches the returned text to the message.
---@field on_widget? fun(key: string, lines: string[]?, placement: string?): agent_workbench.CustomBlock? Handle extension setWidget calls. Return a custom block to render inline in history, or nil to ignore. Not called for `:startup` widgets (keys ending with `:startup`), which are always stored as startup announcements and rendered in the system preamble.

---@class agent_workbench.ConfigModule
---@field options agent_workbench.Options
local M = {}

local Os = require("agent-workbench.os")

math.randomseed(os.time())

---@type agent_workbench.Options
local defaults = {
    auto_start_session = true,
    cli = {
        bin = "pi",
        args = {},
    },
    rpc = {
        map_command = nil,
        map_event = nil,
    },
    agent_dir = nil,
    debug = false,
    models = nil,
    spinner = "robot",
    show_thinking = true,
    turn_separator = true,
    expand_startup_details = false,
    timestamp_format = Os.is_windows() and "%b %#d %Y, %H:%M" or "%b %-d %Y, %H:%M",
    panels = {
        history = { title = "π" },
        prompt = { title = "prompt", bash_title = "bash" },
        attachments = { title = "attached" },
    },
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
    layout = {
        default = "buffer",
        side = {
            position = "right",
            width = 80,
            panels = {
                history = { winbar = true },
                prompt = { winbar = true },
                attachments = { winbar = true },
            },
        },
        float = {
            width = 0.6,
            height = 0.8,
            border = "rounded",
        },
    },
    statusline = {
        enabled = false,
        layout = {
            left = { "context", "  ", "attention", "  ", "queue", "  ", "compaction" },
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
    diff = {
        icons = {
            note = "󰆈",
        },
        context = {
            base = nil,
            step = 5,
        },
        keymap_hints = "dialog",
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
    attention = {
        auto_open_on_prompt_focus = true,
        notify_on_completion = true,
    },
    reload = {
        mode = "silent",
    },
    quickfix = {
        grep = true,
        find = false,
        glob = false,
    },
    abort = {
        enabled = true,
        timeout = 1500,
        message = "Press <Esc> again to abort",
    },
    tree = {
        enabled = true,
    },
    workspace_bar = {
        enabled = true,
        show = "multiple",
        label = "name",
        show_index = false,
        session_count = true,
        status = true,
    },
    workspace_buffers = {
        enabled = true,
    },
    workspace_sidebar = {
        position = "right",
        width = 38,
    },
    sessions_list = {
        mode = "follow",
        auto_open = false,
        position = "left",
        width = 40,
        height = 12,
        float = {
            width = 0.5,
            height = 0.4,
            border = "rounded",
        },
    },
    diff_review = {
        width = 0.8,
        height = 0.8,
        border = "rounded",
        list = {
            position = "left",
            width = 30,
        },
    },
    dialog = {
        border = "rounded",
        max_width = 0.8,
        max_height = 0.8,
        keys = {
            confirm = nil,
            cancel = nil,
        },
    },
    zen = {
        width = nil,
        keys = {
            toggle = nil,
            exit = nil,
        },
    },
    prompt = {
        history = {
            enabled = true,
            max = 500,
        },
        draft = {
            enabled = true,
        },
        paste_image = true,
        image_compress = {
            enable = true,
            max_dimension = 1568,
            quality = 80,
            format = "keep",
            tool = "auto",
            scope = "all",
        },
    },
    render = {
        engine = "markview",
    },
    verbs = {
        use_defaults = true,
        pairs = {
            { "rm -rf'ing /", "rm -rf'd /" },
            { "Cooking spaghetti", "Cooked" },
            { "Burning tokens", "Burned tokens" },
            { "Shaving yaks", "Shaved yak" },
            { "Racking up debt", "Racked up debt" },
            { "Mining bitcoins", "Mined ₿" },
            { "Stacking overflow", "Stacked overflow" },
            { "Opening kournikova.jpg", "Opened kournikova.jpg" },
            { "Deploying on Friday", "Deployed on Friday" },
            { "Jiggling wiggling", "Jiggled wiggled" },
            { "Rewriting in Rust", "Rewrote in Rust" },
            { "Git blaming", "Git blamed" },
            { "Tail-recursing", "Stack overflowed" },
            { "Making no mistakes", "Made no mistakes" },
            { "Making your codebase great again", "Made your codebase great again" },
            { "Dangerously skipping permissions", "Dangerously skipped permissions" },
            { "Agently replacing you", "Agently replaced you" },
        },
    },
    on_widget = nil,
    mention_providers = {},
}

---@type agent_workbench.Options
M.options = vim.deepcopy(defaults)

---@param opts? agent_workbench.Options
function M.setup(opts)
    ---@diagnostic disable-next-line: undefined-field -- `bin` was removed; read only to raise a helpful error
    if opts and opts.bin ~= nil then
        error("Agent Workbench: `bin` was removed; use `cli = { bin = ... }`", 2)
    end

    -- Stash user verbs before deep-extend mangles the list.
    local user_verbs = opts and opts.verbs or nil
    if opts then
        opts = vim.deepcopy(opts)
        opts.verbs = nil
    end

    M.options = vim.tbl_deep_extend("force", defaults, opts or {})

    -- Resolve verbs: merge or replace based on use_defaults.
    if user_verbs then
        local use_defaults = user_verbs.use_defaults
        if use_defaults == nil then
            use_defaults = defaults.verbs.use_defaults
        end
        local user_pairs = user_verbs.pairs or {}
        if use_defaults then
            local merged = vim.deepcopy(defaults.verbs.pairs) --[[@as agent_workbench.VerbPair[] ]]
            vim.list_extend(merged, user_pairs)
            M.options.verbs = { use_defaults = true, pairs = merged }
        else
            M.options.verbs = { use_defaults = false, pairs = user_pairs }
        end
    end
end

--- Resolve a config value that may be a function, merging the result with
--- a fallback table when provided.
---@generic T
---@param value T|fun(): T
---@param fallback? T
---@return T
local function resolve(value, fallback)
    if type(value) ~= "function" then
        return value
    end
    local result = value()
    if fallback and type(result) == "table" and type(fallback) == "table" then
        return vim.tbl_deep_extend("force", fallback, result)
    end
    return result
end

--- Resolve layout.default (may be a string or a function returning one).
---@return agent_workbench.LayoutMode
function M.resolve_default_layout_mode()
    return resolve(M.options.layout.default) --[[@as agent_workbench.LayoutMode]]
end

--- Resolve layout.side (may be a table or a function returning a partial table).
---@return agent_workbench.SideLayout
function M.resolve_side_layout()
    return resolve(M.options.layout.side, defaults.layout.side) --[[@as agent_workbench.SideLayout]]
end

--- Resolve layout.float (may be a table or a function returning a partial table).
---@return agent_workbench.FloatLayout
function M.resolve_float_layout()
    return resolve(M.options.layout.float, defaults.layout.float) --[[@as agent_workbench.FloatLayout]]
end

--- Pick a random verb pair, returns { active, done }.
--- Falls back to { "Working", "Completed" } if no custom verbs.
---@return agent_workbench.VerbPair
function M.random_verbs()
    local pairs = M.options.verbs and M.options.verbs.pairs
    if not pairs or #pairs == 0 then
        return { "Working", "Completed" }
    end
    local pick = pairs[math.random(#pairs)]
    if pick[1] == "Deploying on Friday" and os.date("*t").wday ~= 6 then
        return M.random_verbs()
    end
    return pick
end

return M
