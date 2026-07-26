--- Clipboard image paste interception for the prompt buffer.
---
--- Neovim has no "paste" autocmd; the supported hook for paste is the global
--- |vim.paste()| handler (invoked by both GUI |nvim_paste()| and TUI
--- bracketed paste). We wrap it so that a paste landing in the π prompt is
--- inspected: if the system clipboard currently holds an image, the image is
--- attached (via |Pi.paste_image()|) and the text paste is cancelled; any
--- other paste is delegated to the original handler untouched.
---
--- The paste channel only ever carries text (the terminal/GUI does not hand
--- Neovim the clipboard image bytes), so the image is detected by querying
--- the OS clipboard directly through img-clip.nvim at paste time.
local Config = require("pi.config")
local Ft = require("pi.filetypes")

local M = {}

local installed = false

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

--- Build the wrapped |vim.paste()| handler.
---@param orig fun(lines: string[], phase: integer): boolean the original handler
---@return fun(lines: string[], phase: integer): boolean
function M._make_handler(orig)
    return function(lines, phase)
        -- Only single-call pastes (-1) into the prompt are candidates; streamed
        -- text pastes (1/2/3) and every other buffer are delegated unchanged.
        if phase == -1 and vim.bo.filetype == Ft.prompt and Config.options.prompt.paste_image then
            if M._clipboard_has_image() then
                -- Defer the attach: mutating the attachment buffer from inside
                -- the paste handler can hit textlock otherwise.
                vim.schedule(function()
                    require("pi").paste_image()
                end)
                return false -- cancel the (text) paste
            end
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
end

--- Reset install state. Test helper.
function M._reset()
    installed = false
end

return M
