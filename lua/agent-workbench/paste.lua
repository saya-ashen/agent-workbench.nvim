--- Clipboard / drag-and-drop image paste interception for the prompt buffer.
---
--- Neovim has no "paste" autocmd and no buffer-local paste hook: the only
--- supported hook is the global |vim.paste()| handler (invoked by both GUI
--- |nvim_paste()| and TUI bracketed paste). We install a single, idempotent
--- wrapper that is a pure pass-through everywhere except a π prompt buffer:
--- the very first thing it does is check the current filetype, and any
--- non-prompt paste is delegated to the original handler untouched. This keeps
--- the global footprint minimal — paste in the rest of the editor behaves
--- exactly as if π were not loaded.
---
--- Inside a prompt buffer a single-call paste (-1) is inspected:
---   1. a dropped image file path (GUI drag-and-drop hands us the path as text)
---      is attached directly;
---   2. otherwise, if the system clipboard currently holds an image, the image
---      is attached (via |Pi.paste_image()|) and the text paste is cancelled.
--- Any other paste is delegated to the original handler unchanged.
---
--- The paste channel only ever carries text (the terminal/GUI does not hand
--- Neovim the clipboard image bytes), so the clipboard image is detected by
--- querying the OS clipboard directly through img-clip.nvim at paste time.
local Config = require("agent-workbench.config")
local Ft = require("agent-workbench.filetypes")

local M = {}

local installed = false
local autocmd_installed = false

--- Image file extensions recognised for drag-and-drop path attachment.
local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true }

--- Registry of live prompt buffers → their attachment list. Populated by
--- |agent_workbench.ChatPrompt| on creation so the global handler can reach the right
--- attachments without touching session state. Keyed by bufnr so multiple
--- tabs (each with its own prompt) coexist.
---@type table<integer, agent_workbench.ChatAttachments>
local prompts = {}

---@type table<integer, fun(lines: string[], phase: integer): boolean>
local terminal_handlers = {}

--- Register a prompt buffer so pasted image file paths attach to it.
---@param buf integer
---@param attachments agent_workbench.ChatAttachments
function M.register(buf, attachments)
    prompts[buf] = attachments
end

--- Forget a prompt buffer (idempotent).
---@param buf integer
function M.unregister(buf)
    prompts[buf] = nil
    terminal_handlers[buf] = nil
end

---@param buf integer
---@param handler? fun(lines: string[], phase: integer): boolean
function M.set_terminal_handler(buf, handler)
    terminal_handlers[buf] = handler
end

--- Quietly check whether the system clipboard currently holds an image.
--- Never warns: returns false when img-clip is missing, no clipboard tool is
--- available, or the content is not an image.
---@return boolean
function M._clipboard_has_image()
    local ok, clip = pcall(require, "img-clip.clipboard")
    if not ok then
        return false
    end
    if not clip.get_clip_cmd() then
        return false
    end
    return clip.content_is_image() == true
end

--- If `line` is a path to an existing image file, attach it to the prompt that
--- owns `buf`. Handles GUI drag-and-drop, which delivers the file path as text.
---@param buf integer
---@param line string
---@return boolean attached true when the line was consumed as an image drop
local function try_attach_dropped_image(buf, line)
    if line == "" then
        return false
    end
    local ext = line:lower():match("%.(%w+)$")
    if not ext or not IMAGE_EXTS[ext] then
        return false
    end
    local stat = vim.uv.fs_stat(line)
    if not stat or stat.type ~= "file" then
        return false
    end
    local attachments = prompts[buf]
    if not attachments then
        return false
    end
    attachments:add_file(line)
    return true
end

--- Build the wrapped |vim.paste()| handler.
---@param orig fun(lines: string[], phase: integer): boolean the original handler
---@return fun(lines: string[], phase: integer): boolean
function M._make_handler(orig)
    return function(lines, phase)
        local buf = vim.api.nvim_get_current_buf()
        local terminal_handler = terminal_handlers[buf]
        if terminal_handler then
            return terminal_handler(lines, phase)
        end

        -- Streamed editor pastes are delegated immediately.
        if phase ~= -1 then
            return orig(lines, phase)
        end
        -- Scope guarantee: anything outside a π prompt buffer is a pure
        -- pass-through — no clipboard query, no fs_stat, no π logic at all.
        if vim.bo[buf].filetype ~= Ft.prompt then
            return orig(lines, phase)
        end

        -- Single-line paste into a prompt: first try a dropped image file path.
        if #lines == 1 and try_attach_dropped_image(buf, lines[1] or "") then
            return true -- cancel the text paste; the image is attached
        end

        -- Otherwise, attach a clipboard image if there is one.
        if Config.options.prompt.paste_image and M._clipboard_has_image() then
            -- Defer the attach: mutating the attachment buffer from inside the
            -- paste handler can hit textlock otherwise.
            vim.schedule(function()
                require("agent-workbench").paste_image()
            end)
            return false -- cancel the (text) paste
        end

        return orig(lines, phase)
    end
end

--- Install the global |vim.paste()| wrapper. Idempotent. The wrapper reads
--- `prompt.paste_image` at call time, so the feature can be toggled without
--- reinstalling.
function M.setup()
    if installed then
        return
    end
    installed = true
    vim.paste = M._make_handler(vim.paste)

    -- Keep the registry from leaking: drop entries when their buffer goes away.
    -- Guarded separately from `installed` so test resets (which re-run setup)
    -- do not stack duplicate autocmds.
    if not autocmd_installed then
        autocmd_installed = true
        vim.api.nvim_create_autocmd("BufWipeout", {
            callback = function(args)
                prompts[args.buf] = nil
                terminal_handlers[args.buf] = nil
            end,
        })
    end
end

--- Reset install state and registry. Test helper.
function M._reset()
    installed = false
    prompts = {}
    terminal_handlers = {}
end

return M
