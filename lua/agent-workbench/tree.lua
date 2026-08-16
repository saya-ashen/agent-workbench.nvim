--- Session tree navigation (:AgentWorkbenchTree) — frontend for the bundled /tree bridge
--- extension (extensions/tree.ts). Mirrors the pi TUI's /tree: pick an entry
--- from the session tree, optionally summarize the abandoned branch, then the
--- backend moves the session leaf and the chat is rebuilt from the new branch.

local M = {}

local Notify = require("agent-workbench.notify")

-- Optional: reuse the chat's per-tool nerd-font icons as a lightweight marker so
-- a tool-only turn reads as "the agent called <tool>", not as an empty line or
-- as prose. pcall because the picker must still work if the chat UI module is
-- unavailable; the fallback below prints the tool name instead.
local ok_tools, Tools = pcall(require, "pi.ui.chat.tools")
if not ok_tools then
    Tools = nil
end

--- Max characters of a tool argument shown in the preview, and max tools listed
--- before the rest collapse into a "(+N)" suffix.
local MAX_FRAG = 40
local MAX_TOOLS = 2

--- Argument key names that carry the most useful one-line hint per tool, kept in
--- sync with the chat tool renderers (lua/agent-workbench/ui/chat/tools.lua). The first key
--- that holds a non-empty string wins.
---@type table<string, string[]>
local TOOL_ARG_KEYS = {
    bash = { "command", "cmd" },
    read = { "path", "file_path" },
    edit = { "path", "file_path" },
    write = { "path", "file_path" },
    grep = { "pattern", "regex", "path" },
    glob = { "pattern", "path" },
    web_fetch = { "url" },
    web_search = { "query", "pattern" },
}

--- Coerce a tool-call arguments value into a table. Stored entries already carry
--- a table; streaming/custom payloads may carry a JSON string instead.
---@param args any
---@return table?
local function args_table(args)
    if type(args) == "table" then
        return args
    end
    if type(args) == "string" and args ~= "" then
        local ok, decoded = pcall(vim.json.decode, args)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end
    return nil
end

--- Collapse a string to a single trimmed line, truncated to MAX_FRAG.
---@param s string
---@return string
local function one_line(s)
    local flat = vim.trim((s or ""):gsub("%s+", " "))
    if #flat > MAX_FRAG then
        return flat:sub(1, MAX_FRAG) .. "…"
    end
    return flat
end

--- The most useful argument hint for a tool call, or nil when none is available.
---@param name string
---@param args table?
---@return string?
local function tool_fragment(name, args)
    if not args then
        return nil
    end
    for _, key in ipairs(TOOL_ARG_KEYS[name] or {}) do
        local v = args[key]
        if type(v) == "string" and vim.trim(v) ~= "" then
            return one_line(v:match("^[^\n]*"))
        end
    end
    -- fallback: first non-empty string argument
    for _, v in pairs(args) do
        if type(v) == "string" and vim.trim(v) ~= "" then
            return one_line(v:match("^[^\n]*"))
        end
    end
    return nil
end

--- Collect the tool calls of a message content field, in order.
---@param content any
---@return { name: string, args: table? }[]
local function collect_tool_calls(content)
    local tools = {}
    if type(content) ~= "table" then
        return tools
    end
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "toolCall" then
            tools[#tools + 1] = {
                name = part.toolName or part.name or "tool",
                args = args_table(part.arguments or part.args or part.input),
            }
        end
    end
    return tools
end

--- One-line summary of a non-empty list of tool calls, e.g.
--- " cd ~/.local…,  /lua/agent-workbench/tree.lua (+1)". Each tool is prefixed by its chat
--- icon when available (the lightweight marker), otherwise by "name: ".
---@param tools { name: string, args: table? }[]
---@return string
local function format_tool_calls(tools)
    local cells = {}
    for i = 1, math.min(#tools, MAX_TOOLS) do
        local t = tools[i]
        local frag = tool_fragment(t.name, t.args)
        if Tools then
            local icon = Tools.get_tool_icon(t.name)
            cells[#cells + 1] = frag and (icon .. " " .. frag) or icon
        else
            cells[#cells + 1] = frag and (t.name .. ": " .. frag) or t.name
        end
    end
    local text = table.concat(cells, ", ")
    local extra = #tools - MAX_TOOLS
    if extra > 0 then
        text = text .. " (+" .. extra .. ")"
    end
    return text
end

---@class agent_workbench.TreeRpcNode
---@field entry table SessionEntry from the RPC get_tree response
---@field children agent_workbench.TreeRpcNode[]
---@field label? string resolved branch label

---@class agent_workbench.TreeItem
---@field id string entry id
---@field depth integer branch depth: the number of forks (multi-child nodes) above
---  this entry, not its position in the conversation. A linear chain stays at
---  depth 0 so long sessions remain readable in the picker instead of marching
---  off the right edge.
---@field kind "user"|"assistant"|"summary"|"compaction"|"custom"
---@field text string single-line preview
---@field label? string resolved branch label
---@field is_leaf boolean whether this entry is the current session leaf
---@field editor_text? string text to prefill into the prompt after navigating here
---@field preview_kind "text"|"tools"|"status"|"empty" what the preview text is:
---  real message text, a tool-call summary, an aborted/error status marker, or an
---  empty placeholder (never the old "(no text)")

--- Map a session entry to a picker kind, or nil when the entry should be
--- hidden (its children are still traversed).
---@param entry table
---@return string? kind
function M.entry_kind(entry)
    local t = entry.type
    if t == "message" then
        local role = entry.message and entry.message.role
        if role == "user" then
            return "user"
        elseif role == "assistant" then
            return "assistant"
        end
        return nil -- toolResult and other roles
    elseif t == "custom_message" then
        return "custom"
    elseif t == "branch_summary" then
        return "summary"
    elseif t == "compaction" then
        return "compaction"
    end
    return nil
end

--- Concatenate the text parts of a message/custom content field.
---@param content string|table?
---@return string
local function content_text(content)
    if type(content) == "string" then
        return content
    end
    local text = ""
    if type(content) == "table" then
        for _, part in ipairs(content) do
            if type(part) == "string" then
                text = text .. part
            elseif type(part) == "table" and part.type == "text" then
                text = text .. (part.text or "")
            end
        end
    end
    return text
end

--- Full text an entry carries, by entry type.
---@param entry table
---@return string
function M.entry_full_text(entry)
    local t = entry.type
    if t == "message" then
        return content_text(entry.message and entry.message.content)
    elseif t == "custom_message" then
        return content_text(entry.content)
    elseif t == "branch_summary" or t == "compaction" then
        return entry.summary or ""
    end
    return ""
end

--- Single-line preview of an entry plus the kind of that preview. The preview is
--- never empty: a text-less assistant turn falls back to a tool-call summary
--- ("tools"), an aborted/errored turn to a status marker ("status"), and anything
--- else to "(empty)". This replaces the old "(no text)" placeholder that made
--- long, tool-heavy sessions unreadable in the picker.
---@param entry table
---@return string text, "text"|"tools"|"status"|"empty" kind
function M.entry_preview(entry)
    local text = vim.trim(M.entry_full_text(entry):gsub("%s+", " "))
    if text ~= "" then
        return text, "text"
    end
    local content = entry.type == "message" and entry.message and entry.message.content or nil
    local tools = collect_tool_calls(content)
    if #tools > 0 then
        return format_tool_calls(tools), "tools"
    end
    local message = entry.type == "message" and entry.message or nil
    local stop = message and message.stopReason
    if stop == "aborted" then
        return "(aborted)", "status"
    end
    if stop == "error" then
        local em = message and message.errorMessage
        if type(em) == "string" then
            local frag = one_line(em:match("^[^\n]*"))
            if frag ~= "" then
                return "(error: " .. frag .. ")", "status"
            end
        end
        return "(error)", "status"
    end
    return "(empty)", "empty"
end

--- Text to prefill into the prompt after navigating to an entry, mirroring
--- navigateTree's editorText semantics: user and custom messages are placed
--- back into the editor for editing/resending (the leaf moves to the entry's
--- parent). Anything else returns nil.
---@param entry table
---@return string?
function M.editor_text(entry)
    local t = entry.type
    if t == "message" and entry.message and entry.message.role == "user" then
        local text = content_text(entry.message.content)
        if text ~= "" then
            return text
        end
    elseif t == "custom_message" then
        local text = content_text(entry.content)
        if text ~= "" then
            return text
        end
    end
    return nil
end

--- Flatten the RPC tree into a display-ordered item list (DFS). Entries whose
--- kind is nil are hidden but their children are still traversed, at the same
--- depth.
---
--- Depth counts *branching*, not conversation length: descending into a node's
--- children only adds a level when there is more than one child (a genuine fork
--- with alternatives). A single child is just the conversation continuing, so it
--- stays at the same depth. This keeps a long linear session flat and readable
--- instead of indenting every message one more level and pushing the preview
--- text off the edge of the picker.
---@param nodes agent_workbench.TreeRpcNode[]
---@param leaf_id string? current session leaf id
---@return agent_workbench.TreeItem[]
function M.flatten(nodes, leaf_id)
    ---@type agent_workbench.TreeItem[]
    local items = {}
    local function visit(node, depth)
        local entry = node.entry or {}
        local kind = M.entry_kind(entry)
        if kind then
            local text, preview_kind = M.entry_preview(entry)
            items[#items + 1] = {
                id = entry.id,
                depth = depth,
                kind = kind,
                text = text,
                preview_kind = preview_kind,
                label = node.label,
                is_leaf = entry.id ~= nil and entry.id == leaf_id,
                editor_text = M.editor_text(entry),
            }
        end
        local children = node.children or {}
        local child_depth = depth
        if #children > 1 then
            child_depth = depth + 1
        end
        for _, child in ipairs(children) do
            visit(child, child_depth)
        end
    end
    for _, node in ipairs(nodes or {}) do
        visit(node, 0)
    end
    return items
end

--- Build the /tree bridge command sent as an RPC prompt.
---@param entry_id string
---@param mode "none"|"summary"|"custom"
---@param instructions? string custom summarization instructions (mode = "custom")
---@return string
function M.build_command(entry_id, mode, instructions)
    if mode == "custom" and instructions and instructions ~= "" then
        return "/tree " .. entry_id .. " custom " .. instructions
    end
    return "/tree " .. entry_id .. " " .. mode
end

--- One-line picker label for an item. The branch label (if any) sits right after
--- the [kind] tag, before the preview text, so it stays visible even when a long
--- preview is truncated by the picker width.
---@param item agent_workbench.TreeItem
---@return string
function M.format_item(item)
    local indent = string.rep("  ", item.depth or 0)
    local leaf = item.is_leaf and "● " or "  "
    local label = item.label and ("⚑ " .. item.label .. " ") or ""
    local text = item.text ~= "" and item.text or "(empty)"
    return string.format("%s%s[%s] %s%s", indent, leaf, item.kind, label, text)
end

---@alias agent_workbench.TreeSummaryChoice "none"|"summary"|"custom"

--- Ask whether the abandoned branch should be summarized (mirrors the TUI).
---@param cb fun(choice: agent_workbench.TreeSummaryChoice?, instructions: string?)
local function select_summary(cb)
    local options = { "No summary", "Summarize", "Summarize with custom prompt" }
    vim.ui.select(options, { prompt = "Summarize branch?" }, function(choice)
        if not choice then
            cb(nil)
            return
        end
        if choice == "No summary" then
            cb("none")
        elseif choice == "Summarize" then
            cb("summary")
        else
            vim.ui.input({ prompt = "Custom summarization instructions: " }, function(input)
                if input == nil then
                    -- Cancelled at the instructions prompt: back to the summary choice.
                    select_summary(cb)
                    return
                end
                cb("custom", input)
            end)
        end
    end)
end

--- Open the tree picker and navigate the session to the selected entry.
function M.open()
    local Config = require("agent-workbench.config")
    if (Config.options.tree or {}).enabled == false then
        Notify.warn("Session tree navigation is disabled (tree.enabled = false)")
        return
    end

    local Sessions = require("agent-workbench.sessions.manager")
    local session = Sessions.get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end
    if session.chat:is_streaming() then
        Notify.warn("Wait for the agent to finish before navigating the session tree")
        return
    end

    session.rpc:send({ type = "get_tree" }, function(res)
        if not res.success then
            vim.schedule(function()
                Notify.error(res.error or "Failed to get session tree")
            end)
            return
        end
        local data = res.data or {}
        local items = M.flatten(data.tree, data.leafId)
        vim.schedule(function()
            if #items == 0 then
                Notify.info("No entries in session")
                return
            end
            M._pick(session, items, data.leafId)
        end)
    end)
end

--- Picker → summary choice → navigate. Re-shows the picker when the summary
--- choice is cancelled (mirrors the TUI's Escape behavior).
---@param session agent_workbench.Session
---@param items agent_workbench.TreeItem[]
---@param leaf_id string?
function M._pick(session, items, leaf_id)
    vim.ui.select(items, {
        prompt = "Navigate to (● = current)",
        format_item = M.format_item,
    }, function(item)
        if not item then
            return
        end
        if item.id == leaf_id then
            Notify.info("Already at this point")
            return
        end
        select_summary(function(mode, instructions)
            if not mode then
                -- Cancelled at the summary choice: back to the tree picker.
                M._pick(session, items, leaf_id)
                return
            end
            M._navigate(session, item, mode, instructions)
        end)
    end)
end

--- Send the /tree bridge command and rebuild the chat from the new branch.
---@param session agent_workbench.Session
---@param item agent_workbench.TreeItem
---@param mode agent_workbench.TreeSummaryChoice
---@param instructions? string
function M._navigate(session, item, mode, instructions)
    local command = M.build_command(item.id, mode, instructions)
    session.chat:set_status({ type = "agent", text = mode == "none" and "Navigating…" or "Summarizing branch…" })

    local sent = session.rpc:send({ type = "prompt", message = command }, function(res)
        vim.schedule(function()
            session.chat:set_status(nil)
            if not res.success then
                Notify.error(res.error or "Tree navigation failed")
                return
            end
            local Sessions = require("agent-workbench.sessions.manager")
            Sessions.reload_messages(session)
            if item.editor_text then
                session.chat:_set_prompt_draft(item.editor_text)
            end
        end)
    end)
    if not sent then
        session.chat:set_status(nil)
        Notify.error("Failed to send tree navigation command")
    end
end

return M
