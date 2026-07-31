--- Session tree navigation (:PiTree) — frontend for the bundled /tree bridge
--- extension (extensions/tree.ts). Mirrors the pi TUI's /tree: pick an entry
--- from the session tree, optionally summarize the abandoned branch, then the
--- backend moves the session leaf and the chat is rebuilt from the new branch.

local M = {}

local Notify = require("pi.notify")

---@class pi.TreeRpcNode
---@field entry table SessionEntry from the RPC get_tree response
---@field children pi.TreeRpcNode[]
---@field label? string resolved branch label

---@class pi.TreeItem
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

--- Single-line preview of an entry's text.
---@param entry table
---@return string
function M.entry_preview(entry)
    local text = M.entry_full_text(entry):gsub("%s+", " ")
    return vim.trim(text)
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
---@param nodes pi.TreeRpcNode[]
---@param leaf_id string? current session leaf id
---@return pi.TreeItem[]
function M.flatten(nodes, leaf_id)
    ---@type pi.TreeItem[]
    local items = {}
    local function visit(node, depth)
        local entry = node.entry or {}
        local kind = M.entry_kind(entry)
        if kind then
            items[#items + 1] = {
                id = entry.id,
                depth = depth,
                kind = kind,
                text = M.entry_preview(entry),
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
---@param item pi.TreeItem
---@return string
function M.format_item(item)
    local indent = string.rep("  ", item.depth or 0)
    local leaf = item.is_leaf and "● " or "  "
    local label = item.label and ("⚑ " .. item.label .. " ") or ""
    local text = item.text ~= "" and item.text or "(no text)"
    return string.format("%s%s[%s] %s%s", indent, leaf, item.kind, label, text)
end

---@alias pi.TreeSummaryChoice "none"|"summary"|"custom"

--- Ask whether the abandoned branch should be summarized (mirrors the TUI).
---@param cb fun(choice: pi.TreeSummaryChoice?, instructions: string?)
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
    local Config = require("pi.config")
    if (Config.options.tree or {}).enabled == false then
        Notify.warn("Session tree navigation is disabled (tree.enabled = false)")
        return
    end

    local Sessions = require("pi.sessions.manager")
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
---@param session pi.Session
---@param items pi.TreeItem[]
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
---@param session pi.Session
---@param item pi.TreeItem
---@param mode pi.TreeSummaryChoice
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
            local Sessions = require("pi.sessions.manager")
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
