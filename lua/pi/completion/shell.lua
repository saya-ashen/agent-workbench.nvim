local Completion = require("pi.ui.chat.terminal.shell.completion")

---@class pi.ShellCompletionSource
local Source = {}
Source.__index = Source

---@return pi.ShellCompletionSource
function Source.new()
    return setmetatable({}, Source)
end

---@return boolean
function Source:enabled()
    return vim.b.pi_shell_blink_completion == true and vim.b.pi_shell_worksheet == true
end

---@return string[]
function Source:get_trigger_characters()
    return { " ", "-", "=", "/", ".", "$", "~" }
end

---@param context table
---@param callback fun(response: table)
---@return fun()
function Source:get_completions(context, callback)
    local Worksheet = require("pi.ui.chat.terminal.worksheet")
    ---@type pi.ShellWorksheet?
    local worksheet = Worksheet.for_buffer(context.bufnr)
    local shell_context = worksheet and worksheet:completion_context(context.cursor) or nil
    if
        not worksheet
        or not shell_context
        or (shell_context.base == "" and vim.trim(shell_context.commandline) == "")
    then
        callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = {} })
        return function() end
    end

    local cancelled = false
    worksheet:request_completion(shell_context.commandline, shell_context.base, function(output, parent_output)
        if cancelled then
            return
        end
        local items = {}
        for _, candidate in ipairs(Completion.parse_with_parent(output, shell_context.base, parent_output)) do
            local description = candidate.menu:gsub("^%[fish%]%s*", "")
            local current_option = #shell_context.base > 1
                and shell_context.base:sub(1, 1) == "-"
                and shell_context.base:sub(1, 2) ~= "--"
                and candidate.word == shell_context.base
            items[#items + 1] = {
                label = candidate.abbr,
                filterText = candidate.word,
                sortText = current_option and "!" or nil,
                score_offset = current_option and 1000 or nil,
                labelDetails = description ~= "" and { description = description } or nil,
                documentation = description ~= "" and { kind = "plaintext", value = description } or nil,
                textEdit = {
                    newText = candidate.word,
                    range = {
                        start = { line = context.cursor[1] - 1, character = shell_context.start_col - 1 },
                        ["end"] = { line = context.cursor[1] - 1, character = context.cursor[2] },
                    },
                },
            }
        end
        callback({ is_incomplete_forward = true, is_incomplete_backward = true, items = items })
    end)
    return function()
        cancelled = true
    end
end

return Source
