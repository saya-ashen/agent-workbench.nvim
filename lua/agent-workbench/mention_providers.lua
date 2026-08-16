--- Dynamic @-mention providers: materialize editor/git state into context
--- text that is attached to the message at send time.
---
--- Built-ins: `git-diff`, `git-log`, `lsp-errors`, `quickfix`. Users can
--- register their own via the `mention_providers` config option
--- (name → function returning the context text).

---@class agent_workbench.MentionProviderSpec
---@field fn fun(): string? Returns the context text (nil or empty attaches nothing).
---@field description? string Shown in the completion menu.
---@field lang? string Fence language for the materialized block (default: none).

---@class agent_workbench.MentionProvider
---@field name string mention name without the @ prefix
---@field description string shown in the completion menu
---@field lang? string fence language for the materialized block
---@field fn fun(): string?

local M = {}

local Config = require("agent-workbench.config")
local Notify = require("agent-workbench.notify")

--- Hard cap on one provider's materialized output. A huge diff should not
--- blow up the message; larger payloads are truncated with a marker.
local MAX_CONTENT_BYTES = 256 * 1024

--- Run a shell command in the current cwd, returning trimmed stdout or nil.
---@param args string[]
---@return string?
local function run_cmd(args)
    local ok, proc = pcall(vim.system, args, { cwd = vim.uv.cwd(), text = true })
    if not ok then
        return nil
    end
    local res = proc:wait()
    if res.code ~= 0 then
        return nil
    end
    return vim.trim(res.stdout or "")
end

--- Format the quickfix list as `path:lnum:col: text` lines under its title.
---@return string?
local function quickfix_content()
    local qf = vim.fn.getqflist({ title = true, items = true })
    local lines = {}
    for _, item in ipairs(qf.items or {}) do
        if item.bufnr and item.bufnr > 0 then
            local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(item.bufnr), ":.")
            local col = (item.col and item.col > 0) and (":" .. item.col) or ""
            lines[#lines + 1] = ("%s:%d%s: %s"):format(path, item.lnum or 0, col, vim.trim(item.text or ""))
        end
    end
    if #lines == 0 then
        return nil
    end
    local title = (qf.title and qf.title ~= "") and (qf.title .. "\n") or ""
    return title .. table.concat(lines, "\n")
end

--- Format buffer diagnostics of ERROR severity as `path:lnum:col: message` lines.
---@return string?
local function lsp_errors_content()
    local diags = vim.diagnostic.get(nil, { severity = vim.diagnostic.severity.ERROR })
    table.sort(diags, function(a, b)
        if a.bufnr ~= b.bufnr then
            return a.bufnr < b.bufnr
        end
        if a.lnum ~= b.lnum then
            return a.lnum < b.lnum
        end
        return a.col < b.col
    end)
    local lines = {}
    for _, d in ipairs(diags) do
        local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(d.bufnr), ":.")
        local src = d.source and (" [" .. d.source .. "]") or ""
        lines[#lines + 1] = ("%s:%d:%d: %s%s"):format(path, d.lnum + 1, d.col + 1, vim.trim(d.message or ""), src)
    end
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

--- Built-in providers, in menu order.
---@type agent_workbench.MentionProvider[]
local builtins = {
    {
        name = "git-diff",
        description = "git diff HEAD (staged + unstaged changes)",
        lang = "diff",
        fn = function()
            return run_cmd({ "git", "diff", "HEAD" })
        end,
    },
    {
        name = "git-log",
        description = "git log --oneline -20 (recent commits)",
        lang = "",
        fn = function()
            return run_cmd({ "git", "log", "--oneline", "-20" })
        end,
    },
    {
        name = "lsp-errors",
        description = "LSP diagnostics with ERROR severity",
        lang = "",
        fn = lsp_errors_content,
    },
    {
        name = "quickfix",
        description = "current quickfix list",
        lang = "",
        fn = quickfix_content,
    },
}

--- Normalize a config entry (function or spec table) into a provider.
---@param name string
---@param entry fun(): string?|agent_workbench.MentionProviderSpec
---@return agent_workbench.MentionProvider?
local function normalize(name, entry)
    if type(entry) == "function" then
        return { name = name, description = "custom provider", fn = entry }
    end
    if type(entry) == "table" and type(entry.fn) == "function" then
        return {
            name = name,
            description = entry.description or "custom provider",
            lang = entry.lang,
            fn = entry.fn,
        }
    end
    return nil
end

--- All registered providers: built-ins first (fixed order), then custom
--- providers from config (sorted by name for a stable menu).
---@return agent_workbench.MentionProvider[]
function M.list()
    local providers = {}
    for _, provider in ipairs(builtins) do
        providers[#providers + 1] = provider
    end
    local custom = Config.options.mention_providers or {}
    local names = vim.tbl_keys(custom)
    table.sort(names)
    for _, name in ipairs(names) do
        local provider = normalize(name, custom[name])
        if provider then
            providers[#providers + 1] = provider
        end
    end
    return providers
end

--- Look up a provider by mention name.
---@param name string
---@return agent_workbench.MentionProvider?
function M.get(name)
    for _, provider in ipairs(M.list()) do
        if provider.name == name then
            return provider
        end
    end
    return nil
end

---@param name string
---@return boolean
function M.has(name)
    return M.get(name) ~= nil
end

--- Run a provider and return its materialized content, or nil when it
--- produced nothing. Errors are reported to the user, never raised.
---@param name string
---@return string? content trimmed, truncated to MAX_CONTENT_BYTES
function M.materialize(name)
    local provider = M.get(name)
    if not provider then
        return nil
    end
    local ok, content = pcall(provider.fn)
    if not ok then
        Notify.warn(("Mention provider @%s failed: %s"):format(name, vim.trim(tostring(content))))
        return nil
    end
    if type(content) ~= "string" then
        return nil
    end
    content = vim.trim(content)
    if content == "" then
        return nil
    end
    if #content > MAX_CONTENT_BYTES then
        content = content:sub(1, MAX_CONTENT_BYTES) .. "\n… (truncated)"
    end
    return content
end

return M
