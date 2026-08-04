local M = {}

M.DIALOG_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDialogTitle"
M.CHAT_HISTORY_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatHistoryFloatTitle"
M.CHAT_PROMPT_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatTitle"
M.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT =
    "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatAttentionTitle"
M.CHAT_PROMPT_BASH_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatPromptFloatBashTitle"
M.CHAT_ATTACHMENTS_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiChatAttachmentsFloatTitle"
M.SESSIONS_LIST_WINHIGHLIGHT = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiSessionsListFloatTitle"
M.DIFF_WINHIGHLIGHT = "WinBar:PiDiffWinbar,WinBarNC:PiDiffWinbar"

--- Clear the Pi* groups we previously installed as defaults.
---
--- Every group below is created with `default = true`, which by design never
--- overrides an existing definition (so a user's own `Pi*` highlight wins). The
--- flip side: on a later `:colorscheme`, `default = true` alone is a no-op for
--- groups that already exist. Legacy colorschemes call `:highlight clear` and
--- wipe them for us, but many modern ones (tokyonight, catppuccin, ...) do not,
--- so the colors would stay frozen at the first theme. Clearing our own
--- default-defined groups here lets the `default = true` calls below re-apply
--- against the new theme, while explicit (non-default) user definitions are
--- left untouched and keep priority.
local function clear_default_groups()
    for name, def in pairs(vim.api.nvim_get_hl(0, { link = false })) do
        if name:sub(1, 2) == "Pi" and def.default then
            vim.api.nvim_set_hl(0, name, {})
        end
    end
end

local function set_defaults()
    clear_default_groups()
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
    local func = vim.api.nvim_get_hl(0, { name = "Function", link = false })
    local special = vim.api.nvim_get_hl(0, { name = "Special", link = false })
    local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
    local warning = vim.api.nvim_get_hl(0, { name = "WarningMsg", link = false })
    local diagnostic_error = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
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

    vim.api.nvim_set_hl(0, "PiDialogSelected", { default = true, link = "Visual" })

    vim.api.nvim_set_hl(0, "PiDiffWinbar", { default = true, bg = agent.fg })
    vim.api.nvim_set_hl(0, "PiDiffWinbarCurrent", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarProposed", { default = true, fg = normal.bg, bold = true })
    vim.api.nvim_set_hl(0, "PiDiffWinbarHint", { default = true, fg = normal.bg })
    vim.api.nvim_set_hl(0, "PiDiffReviewNote", { default = true, fg = warning.fg, italic = true })

    vim.api.nvim_set_hl(0, "PiStatusLine", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineAttention", { default = true, fg = warning.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiStatusLineWarning", { default = true, fg = warning.fg })
    vim.api.nvim_set_hl(0, "PiStatusLineError", { default = true, fg = diagnostic_error.fg })

    vim.api.nvim_set_hl(0, "PiSessionsListIdle", { default = true, fg = comment.fg })
    vim.api.nvim_set_hl(0, "PiSessionsListDotDim", { default = true, fg = comment.fg, bold = false })
    vim.api.nvim_set_hl(0, "PiSessionsListCompacting", { default = true, fg = special.fg, bold = true })
    vim.api.nvim_set_hl(0, "PiSessionsListExited", { default = true, fg = diagnostic_error.fg })
    vim.api.nvim_set_hl(0, "PiSessionsListPending", { default = true, fg = comment.fg, italic = true })
    vim.api.nvim_set_hl(0, "PiSessionsListFloatTitle", { default = true, fg = title.fg, bold = true })
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
