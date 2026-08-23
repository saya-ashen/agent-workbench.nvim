local M = {}

M.DIALOG_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDialogTitle"
M.CHAT_HISTORY_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatHistoryFloatTitle"
M.CHAT_PROMPT_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatTitle"
M.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT =
    "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatAttentionTitle"
M.CHAT_PROMPT_BASH_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatBashTitle"
M.CHAT_ATTACHMENTS_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatAttachmentsFloatTitle"
M.SESSIONS_LIST_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiSessionsListFloatTitle"
M.DIFF_REVIEW_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDiffReviewFloatTitle"
M.DIFF_WINHIGHLIGHT = "WinBar:PiDiffWinbar,WinBarNC:PiDiffWinbar"

---@class agent_workbench.DefaultHighlightFingerprint
---@field definition table<string, any>

---@type table<string, agent_workbench.DefaultHighlightFingerprint>
local default_fingerprints = {}

---@param name string
---@return boolean
local function is_plugin_group(name)
    return name:sub(1, 2) == "Pi" or name:sub(1, 22) == "AgentWorkbenchMarkdown"
end

---@param definition table<string, any>
---@return table<string, any>
local function comparable_definition(definition)
    local comparable = vim.deepcopy(definition)
    comparable.default = nil
    return comparable
end

--- Clear only the Pi*/Markdown groups whose current definitions still match
--- defaults installed by this module. Neovim 0.10/0.11 do not report the
--- `default` flag from nvim_get_hl(), so fingerprints are required to preserve
--- explicit user overrides while still refreshing colorscheme-derived values.
---@return table<string, boolean> preexisting groups that defaults must not own
local function clear_default_groups()
    local definitions = vim.api.nvim_get_hl(0, { link = false })
    local fingerprints = default_fingerprints
    default_fingerprints = {}
    for name, fingerprint in pairs(fingerprints) do
        local current = definitions[name] or {}
        local comparable = comparable_definition(current)
        -- Some colorscheme operations strip the reported `default` flag from
        -- unchanged groups, so the normalized definition remains authoritative.
        local owned = current.default == true or vim.deep_equal(comparable, fingerprint.definition)
        if owned then
            vim.api.nvim_set_hl(0, name, {})
        end
    end
    -- Also clear module defaults left behind by a Lua module reload on Neovim
    -- versions that expose the flag directly.
    definitions = vim.api.nvim_get_hl(0, { link = false })
    for name, definition in pairs(definitions) do
        if is_plugin_group(name) and definition.default then
            vim.api.nvim_set_hl(0, name, {})
        end
    end
    local preexisting = {}
    for name, definition in pairs(vim.api.nvim_get_hl(0, { link = false })) do
        if is_plugin_group(name) and next(comparable_definition(definition)) ~= nil then
            preexisting[name] = true
        end
    end
    return preexisting
end

---@param preexisting table<string, boolean>
local function remember_default_groups(preexisting)
    for name, definition in pairs(vim.api.nvim_get_hl(0, { link = false })) do
        if is_plugin_group(name) and not preexisting[name] then
            default_fingerprints[name] = { definition = comparable_definition(definition) }
        end
    end
end

local function set_defaults()
    local preexisting = clear_default_groups()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
    local func = vim.api.nvim_get_hl(0, { name = "Function", link = false })
    local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
    local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    local warning = vim.api.nvim_get_hl(0, { name = "WarningMsg", link = false })
    local diagnostic_error = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
    local diagnostic_info = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
    local diagnostic_ok = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false })
    local underlined = vim.api.nvim_get_hl(0, { name = "Underlined", link = false })
    local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
    local delimiter = vim.api.nvim_get_hl(0, { name = "Delimiter", link = false })
    local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
    local diff_add = vim.api.nvim_get_hl(0, { name = "DiffAdd", link = false })
    local diff_delete = vim.api.nvim_get_hl(0, { name = "DiffDelete", link = false })
    local diff_added = vim.api.nvim_get_hl(0, { name = "diffAdded", link = false })
    local diff_removed = vim.api.nvim_get_hl(0, { name = "diffRemoved", link = false })
    local gitsigns_add = vim.api.nvim_get_hl(0, { name = "GitSignsAdd", link = false })
    local gitsigns_delete = vim.api.nvim_get_hl(0, { name = "GitSignsDelete", link = false })

    local user = title
    local agent = func

    -- Themes store the "added/removed" hue in different places: default vim
    -- paints it as the DiffAdd/DiffDelete background, tokyonight exposes it on
    -- diffAdded/GitSignsAdd. Prefer an explicit foreground, then the gitsigns
    -- semantic hue, then the diff background as a last resort, so a diff +/-
    -- sign always reads in the diff's semantic color regardless of theme.
    local function diff_sign_fg(diff, named, gitsign)
        return diff.fg or named.fg or gitsign.fg or diff.bg or comment.fg
    end

    if user.fg then
        vim.api.nvim_set_hl(0, "PiUserMessageLabel", { default = true, fg = user.fg, bold = true })
    end
    if agent.fg then
        vim.api.nvim_set_hl(0, "PiAgentResponseLabel", { default = true, fg = agent.fg, bold = true })
    end
    vim.api.nvim_set_hl(0, "PiAgentSectionLabel", { default = true, fg = normal.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiDebugLabel", { default = true, fg = normal.bg, bg = comment.fg, bold = true })
    vim.api.nvim_set_hl(
        0,
        "PiStartupLabel",
        { default = true, fg = normal.bg, bg = comment.fg, bold = true, nocombine = true }
    )
    vim.api.nvim_set_hl(0, "PiStartupHint", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiStartupDetail", { default = true, fg = comment.fg, nocombine = true })
    vim.api.nvim_set_hl(0, "PiStartupError", { default = true, fg = diagnostic_error.fg, nocombine = true })
    vim.api.nvim_set_hl(
        0,
        "PiCompactionLabel",
        { default = true, fg = normal.bg, bg = comment.fg, bold = true, nocombine = true }
    )
    vim.api.nvim_set_hl(0, "PiCompactionText", { default = true, fg = comment.fg, italic = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiCompactionHint", { default = true, fg = comment.fg, italic = true, nocombine = true })
    vim.api.nvim_set_hl(0, "PiMessageDateTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiMessageQueueTag", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiPendingQueueLabel", { default = true, fg = warning.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiPendingQueueText", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiMessageAttachments", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiUserBody", { default = true, fg = title.fg })
    vim.api.nvim_set_hl(0, "PiAssistantBlockBorder", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiErrorRail", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiSystemErrorIcon", { default = true, fg = diagnostic_error.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiToolInlineDone", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiThinking", { default = true, fg = special.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiThinkingPreview", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolBorder", { default = true, fg = comment.fg })
    -- Subtle background for tool body lines (only when terminal has opaque bg)
    local tool_bg = cursorline.bg
    if tool_bg then
        vim.api.nvim_set_hl(0, "PiToolBody", { default = true, bg = tool_bg })
    else
        vim.api.nvim_set_hl(0, "PiToolBody", { default = true })
    end
    vim.api.nvim_set_hl(0, "PiToolHeader", { default = true, fg = func.fg, bold = true })
    -- Tool input is the agent's "action" — the main body level, so it reads in
    -- normal text color; output/summary/metadata stay Comment to recede.
    vim.api.nvim_set_hl(0, "PiToolCall", { default = true, fg = normal.fg })
    vim.api.nvim_set_hl(0, "PiToolOutput", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolStatus", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolCollapsed", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolError", { default = true, fg = diagnostic_error.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiToolRunning", { default = true, fg = func.fg })
    vim.api.nvim_set_hl(0, "PiWarning", { default = true, fg = warning.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiTableBorder", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiTableHeader", { default = true, bold = true })

    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownHeading1", { default = true, fg = title.fg, bold = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownHeading2", { default = true, fg = title.fg, bold = true })
    for level = 3, 6 do
        -- Lower heading levels keep the body foreground and use weight alone,
        -- so they cannot collapse into the link/inline-code accent colors.
        vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownHeading" .. level, { default = true, bold = true })
    end
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownStrong", { default = true, bold = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownEmphasis", { default = true, italic = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownStrikethrough", { default = true, strikethrough = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownLink", {
        default = true,
        fg = underlined.fg or diagnostic_info.fg or special.fg,
        underline = true,
    })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownInlineCode", {
        default = true,
        fg = string_hl.fg or special.fg,
        bg = cursorline.bg,
    })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownCodeBlock", { default = true, bg = cursorline.bg })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownCodeInfo", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownBlockQuote", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownListMarker", {
        default = true,
        fg = delimiter.fg or comment.fg,
        bold = true,
    })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownCheckboxChecked", {
        default = true,
        fg = diagnostic_ok.fg or string_hl.fg or func.fg,
    })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownCheckboxUnchecked", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownTableHeader", { default = true, bold = true })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownTableBorder", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "AgentWorkbenchMarkdownHorizontalRule", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiDiffAdd", { default = true, link = "DiffAdd" })
    vim.api.nvim_set_hl(0, "PiDiffDelete", { default = true, link = "DiffDelete" })
    vim.api.nvim_set_hl(0, "PiDiffLineNr", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(
        0,
        "PiDiffAddSign",
        { default = true, fg = diff_sign_fg(diff_add, diff_added, gitsigns_add), bold = true }
    )
    vim.api.nvim_set_hl(
        0,
        "PiDiffDeleteSign",
        { default = true, fg = diff_sign_fg(diff_delete, diff_removed, gitsigns_delete), bold = true }
    )
    vim.api.nvim_set_hl(0, "PiDebug", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiError", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiWelcome", { default = true, fg = agent.fg })
    vim.api.nvim_set_hl(0, "PiWelcomeHint", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiBusy", { default = true, fg = agent.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiBusyTime", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiAbortHint", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiAborted", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiMention", { default = true, fg = normal.fg, underline = true })
    vim.api.nvim_set_hl(0, "PiCommand", { default = true, fg = func.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiPromptRequestTitle", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiPromptRequestSelected", { default = true, fg = func.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiShellPrompt", { default = true, fg = func.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiShellRunning", { default = true, fg = warning.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiShellSuccess", { default = true, fg = func.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiShellFailure", { default = true, fg = diagnostic_error.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiShellPath", { default = true, fg = title.fg, underline = true })
    vim.api.nvim_set_hl(0, "PiShellUrl", { default = true, link = "Underlined" })
    vim.api.nvim_set_hl(0, "PiShellDiffHunk", { default = true, fg = special.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiAttachmentFilename", { default = true, fg = normal.fg })
    vim.api.nvim_set_hl(0, "PiAttachmentIcon", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiAttachmentSize", { default = true, link = "Comment" })

    vim.api.nvim_set_hl(0, "PiChatHistoryWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatHistoryWinbarTitle", { default = true, fg = user.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiChatPromptWinbarTitle", { default = true, fg = comment.fg, bg = normal.bg, bold = true })
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptWinbarAttentionTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptWinbarBashTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(0, "PiChatAttachmentsWinbar", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(
        0,
        "PiChatAttachmentsWinbarTitle",
        { default = true, fg = comment.fg, bg = normal.bg, bold = true }
    )

    vim.api.nvim_set_hl(0, "PiFloat", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiFloatBorder", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDialogTitle", { default = true, fg = title.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatHistoryFloatTitle", { default = true, fg = user.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiChatPromptFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptFloatAttentionTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(
        0,
        "PiChatPromptFloatBashTitle",
        { default = true, fg = warning.fg, bg = normal.bg, bold = true }
    )
    vim.api.nvim_set_hl(0, "PiBashHeader", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiBashOutput", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiChatAttachmentsFloatTitle", { default = true, fg = comment.fg, bg = normal.bg })

    vim.api.nvim_set_hl(0, "PiZen", { default = true, bg = normal.bg })
    vim.api.nvim_set_hl(0, "PiZenBackdrop", { default = true, bg = normal.bg })

    vim.api.nvim_set_hl(0, "PiDiffWinbar", { default = true, bg = agent.fg })
    vim.api.nvim_set_hl(0, "PiDiffWinbarCurrent", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarProposed", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarHint", { default = true, fg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDiffReviewNote", { default = true, fg = warning.fg, italic = true })

    vim.api.nvim_set_hl(0, "PiStatusLine", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineAttention", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiStatusLineWarning", { default = true, fg = warning.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineError", { default = true, fg = diagnostic_error.fg })
    -- Bar fill in the :AgentWorkbenchSessionStats dashboard (cost bars; context bar below
    -- the warn/error thresholds uses PiStatusLineWarning/PiStatusLineError).
    vim.api.nvim_set_hl(0, "PiStatsBar", { default = true, fg = func.fg })

    vim.api.nvim_set_hl(0, "PiSessionsListIdle", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiSessionsListDotDim", { default = true, fg = comment.fg, bold = false })
    vim.api.nvim_set_hl(0, "PiSessionsListDone", { default = true, fg = diagnostic_ok.fg or agent.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiSessionsListError", { default = true, fg = diagnostic_error.fg, bold = true })
    -- Busy: yellow blink.
    local diag_warn = vim.api.nvim_get_hl(0, { name = "DiagnosticWarn", link = false })
    vim.api.nvim_set_hl(0, "PiSessionsListBusy", { default = true, fg = diag_warn.fg or special.fg, bold = true })
    -- Window-local current-tab marker: agent color over the dot of the
    -- tab's own session — steady while idle; while busy it blinks (the dim
    -- phase falls through to PiSessionsListDotDim), no background.
    vim.api.nvim_set_hl(0, "PiSessionsListCurrent", { default = true, fg = agent.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiSessionsListCompacting", { default = true, fg = special.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiSessionsListExited", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiSessionsListPending", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiSessionsListFloatTitle", { default = true, fg = title.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffReviewFile", { default = true, fg = title.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffReviewHint", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiDiffReviewFloatTitle", { default = true, fg = title.fg, bold = true })
    remember_default_groups(preexisting)
end

function M.setup()
    -- Apply immediately: pi is typically lazy-loaded on demand (e.g. via a
    -- keymap), which happens *after* VimEnter and without a ColorScheme event,
    -- so the autocmds below would otherwise never fire and every Pi* group
    -- would stay undefined (fg = nil → role icons render in the default color).
    -- The autocmds remain to refresh on a later :colorscheme / VimEnter.
    set_defaults()
    vim.api.nvim_create_autocmd({ "ColorScheme", "VimEnter" }, { callback = set_defaults })
end

return M
