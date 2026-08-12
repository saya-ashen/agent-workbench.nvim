--- User command registration.

local M = {}

---@type table<string, string[]>
local flag_values = { layout = { "buffer", "side", "float" } }

---@param args string
---@return pi.SessionCreateOpts
local function parse_flags(args)
    ---@type pi.SessionCreateOpts
    local flags = {}
    local layout = args:match("layout=(%S+)")
    if layout == "buffer" or layout == "side" or layout == "float" then
        flags.layout = layout
    end
    return flags
end

---@param prefix string
---@return string[]
local function complete_flags(prefix)
    ---@type string[]
    local candidates = {}
    for k, vals in pairs(flag_values) do
        for _, v in ipairs(vals) do
            candidates[#candidates + 1] = k .. "=" .. v
        end
    end
    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:find(prefix, 1, true) == 1
    end, candidates)
end

function M.setup()
    local Pi = require("pi")

    vim.api.nvim_create_user_command("Pi", function(cmd)
        Pi.toggle(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Show or toggle π chat" })

    vim.api.nvim_create_user_command("PiContinue", function(cmd)
        Pi.continue_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Continue last π conversation" })

    vim.api.nvim_create_user_command("PiResume", function(cmd)
        Pi.resume_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Select a past π conversation" })

    vim.api.nvim_create_user_command("PiToggleChat", function()
        Pi.toggle_chat()
    end, { desc = "Toggle π chat window" })

    vim.api.nvim_create_user_command("PiToggleLayout", function()
        Pi.toggle_layout()
    end, { desc = "Toggle π layout (buffer/float)" })

    vim.api.nvim_create_user_command("PiAbort", function()
        Pi.abort()
    end, { desc = "Abort current π operation" })

    vim.api.nvim_create_user_command("PiAbortBash", function()
        Pi.abort_bash()
    end, { desc = "Abort the running direct bash (!) command" })

    vim.api.nvim_create_user_command("PiStop", function()
        Pi.stop()
    end, { desc = "Stop π process and close chat" })

    vim.api.nvim_create_user_command("PiAttention", function()
        Pi.attention()
    end, { desc = "Open the next pending π attention request" })

    vim.api.nvim_create_user_command("PiNewSession", function()
        Pi.new_session()
    end, { desc = "Start new π session" })

    vim.api.nvim_create_user_command("PiTree", function()
        Pi.tree()
    end, { desc = "Navigate π session tree" })

    vim.api.nvim_create_user_command("PiSessions", function()
        Pi.sessions()
    end, { desc = "Toggle π sessions overview list" })

    vim.api.nvim_create_user_command("PiWorkspaces", function()
        Pi.workspaces()
    end, { desc = "Select a π workspace tab" })

    vim.api.nvim_create_user_command("PiNewWorkspace", function()
        Pi.new_workspace()
    end, { desc = "Create a π workspace after selecting its path" })

    vim.api.nvim_create_user_command("PiMoveBuffer", function(cmd)
        local workspace = tonumber(cmd.args)
        if not workspace then
            require("pi.notify").error("Workspace must be a tab number")
            return
        end
        Pi.move_buffer(workspace)
    end, {
        nargs = 1,
        complete = function()
            return require("pi.workspace_buffers").complete_workspaces()
        end,
        desc = "Move current buffer to another π workspace",
    })

    vim.api.nvim_create_user_command("PiSessionStats", function()
        Pi.session_stats()
    end, { desc = "Show π session stats dashboard (tokens, cost, context)" })

    vim.api.nvim_create_user_command("PiDiff", function()
        Pi.diff_review()
    end, { desc = "Review the git diff of every file changed in the current session" })

    vim.api.nvim_create_user_command("PiToggleThinking", function()
        Pi.toggle_thinking()
    end, { desc = "Toggle π thinking visibility" })

    vim.api.nvim_create_user_command("PiToggleStartupDetails", function()
        Pi.toggle_startup_details()
    end, { desc = "Toggle π startup details between compact and expanded" })

    vim.api.nvim_create_user_command("PiCycleThinking", function()
        Pi.cycle_thinking_level()
    end, { desc = "Cycle π thinking level" })

    vim.api.nvim_create_user_command("PiSelectThinking", function()
        Pi.select_thinking_level()
    end, { desc = "Select π thinking level" })

    vim.api.nvim_create_user_command("PiCycleModel", function()
        Pi.cycle_model()
    end, { desc = "Cycle π model" })

    vim.api.nvim_create_user_command("PiSelectModel", function()
        Pi.select_model()
    end, { desc = "Select π model" })

    vim.api.nvim_create_user_command("PiSelectModelAll", function()
        Pi.select_model_all()
    end, { desc = "Select π model from all available (searchable)" })

    vim.api.nvim_create_user_command("PiSendMention", function(args)
        Pi.send_mention(args)
    end, { range = true, desc = "Send file or selection as @mention to Pi prompt" })

    vim.api.nvim_create_user_command("PiAttachImage", function(cmd)
        Pi.attach_image(cmd.args)
    end, { nargs = 1, complete = "file", desc = "Attach image file at path to π prompt" })

    vim.api.nvim_create_user_command("PiPasteImage", function()
        Pi.paste_image()
    end, { desc = "Paste an image from the clipboard as π attachment" })

    vim.api.nvim_create_user_command("PiCompact", function(cmd)
        local instructions = cmd.args ~= "" and cmd.args or nil
        Pi.compact(instructions)
    end, { nargs = "?", desc = "Compact π conversation context" })

    vim.api.nvim_create_user_command("PiToggleAutoCompaction", function()
        Pi.toggle_auto_compaction()
    end, { desc = "Toggle π automatic context compaction" })

    vim.api.nvim_create_user_command("PiSessionName", function(cmd)
        local name = cmd.args ~= "" and cmd.args or nil
        Pi.set_session_name(name)
    end, { nargs = "?", desc = "Set or show π session display name" })

    vim.api.nvim_create_user_command("PiToggleDebug", function()
        Pi.toggle_debug()
    end, { desc = "Toggle π RPC debug logging" })
end

return M
