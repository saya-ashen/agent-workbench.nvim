--- External-tool image compression for prompt attachments.
---
--- Neovim has no image codec and pi's built-in resize (photon WASM) is not
--- reachable from Lua, so compression shells out to a platform tool, probed
--- in order: macOS `sips` (zero-dependency), ImageMagick `magick`, `ffmpeg`.
--- All executions are async (|vim.system()|) so pasting never blocks the UI.
---
--- The caller owns all temp files: the callback receives the output temp
--- path and must read and unlink it.
local M = {}

---@alias pi.ImageCompressTool "sips"|"magick"|"ffmpeg"

--- Tools probed in order when `tool = "auto"`. sips ships with macOS.
local TOOL_PRIORITY = { "sips", "magick", "ffmpeg" }

local MIME_TO_FORMAT = { ["image/jpeg"] = "jpeg", ["image/png"] = "png", ["image/webp"] = "webp" }
local FORMAT_TO_MIME = { jpeg = "image/jpeg", png = "image/png", webp = "image/webp" }
local FORMAT_TO_EXT = { jpeg = ".jpg", png = ".png", webp = ".webp" }

--- Cached auto-detection result; `false` = probed and none found.
---@type string|false?
local detected_tool = nil

--- Executable check, extracted so tests can stub it.
---@param tool string
---@return boolean
function M._is_executable(tool)
    return vim.fn.executable(tool) == 1
end

--- Resolve the compression tool for `configured` ("auto" probes once and
--- caches). Returns nil when no suitable tool is available.
---@param configured string "auto" or a pi.ImageCompressTool
---@return pi.ImageCompressTool?
function M._detect_tool(configured)
    if configured ~= "auto" then
        return M._is_executable(configured) and configured or nil
    end
    if detected_tool == nil then
        detected_tool = false
        for _, tool in ipairs(TOOL_PRIORITY) do
            if M._is_executable(tool) then
                detected_tool = tool
                break
            end
        end
    end
    ---@cast detected_tool -boolean
    return detected_tool or nil
end

--- Whether `mime` may go through the compressor. SVG (vector) and GIF
--- (animation) are never touched — re-encoding would destroy them.
---@param mime string
---@return boolean
function M.supported(mime)
    return MIME_TO_FORMAT[mime] ~= nil
end

---@param format string "jpeg"|"png"|"webp"
---@return string mime
function M._format_mime(format)
    return FORMAT_TO_MIME[format]
end

---@param format string "jpeg"|"png"|"webp"
---@return string ext including the dot
function M._format_ext(format)
    return FORMAT_TO_EXT[format]
end

--- Resolve the effective output format. `keep` maps to the input format;
--- `webp` degrades to `keep` under sips (sips cannot reliably write webp).
---@param cfg pi.ImageCompressConfig
---@param tool pi.ImageCompressTool
---@param input_mime string
---@return string format "jpeg"|"png"|"webp"
function M._resolve_format(cfg, tool, input_mime)
    local format = cfg.format or "keep"
    if format ~= "jpeg" and format ~= "png" and format ~= "webp" and format ~= "keep" then
        format = "keep"
    end
    if format == "keep" or (format == "webp" and tool == "sips") then
        -- Callers guard with M.supported(input_mime), so the mime is always a known
        -- image type and this lookup never misses; the cast states that invariant.
        return MIME_TO_FORMAT[input_mime] --[[@as string]]
    end
    return format
end

--- Whether compression with these settings would be a no-op: PNG output is
--- lossless, so without a resize the tool would only re-encode the input.
---@param cfg pi.ImageCompressConfig
---@param format string resolved output format
---@return boolean
function M._is_noop(cfg, format)
    return (cfg.max_dimension or 0) <= 0 and format == "png"
end

--- Build the argv for `tool`.
---@param tool pi.ImageCompressTool
---@param input string
---@param output string
---@param opts { max_dimension: integer, quality: integer, format: string } resolved values
---@return string[]
function M._build_cmd(tool, input, output, opts)
    if tool == "sips" then
        local cmd = { "sips" }
        if opts.max_dimension > 0 then
            cmd[#cmd + 1] = "-Z"
            cmd[#cmd + 1] = tostring(opts.max_dimension)
        end
        vim.list_extend(cmd, { "-s", "format", opts.format })
        if opts.format == "jpeg" then
            vim.list_extend(cmd, { "-s", "formatOptions", tostring(opts.quality) })
        end
        cmd[#cmd + 1] = input
        vim.list_extend(cmd, { "--out", output })
        return cmd
    end
    if tool == "magick" then
        local cmd = { "magick", input }
        if opts.max_dimension > 0 then
            -- "WxH>" shrinks only images larger than the box, aspect preserved.
            vim.list_extend(cmd, { "-resize", ("%dx%d>"):format(opts.max_dimension, opts.max_dimension) })
        end
        if opts.format ~= "png" then
            vim.list_extend(cmd, { "-quality", tostring(opts.quality) })
        end
        cmd[#cmd + 1] = output
        return cmd
    end
    -- ffmpeg
    local cmd = { "ffmpeg", "-y", "-i", input }
    if opts.max_dimension > 0 then
        vim.list_extend(cmd, {
            "-vf",
            ("scale=w=%d:h=%d:force_original_aspect_ratio=decrease"):format(opts.max_dimension, opts.max_dimension),
        })
    end
    if opts.format == "jpeg" then
        -- ffmpeg qscale runs 2 (best) .. 31 (worst); map quality 0-100 onto it.
        local q = math.floor((100 - opts.quality) / 100 * 29 + 2 + 0.5)
        vim.list_extend(cmd, { "-q:v", tostring(q) })
    elseif opts.format == "webp" then
        vim.list_extend(cmd, { "-quality", tostring(opts.quality) })
    end
    cmd[#cmd + 1] = output
    return cmd
end

--- Compress an image file asynchronously.
---
---@param input string source image path (never modified)
---@param input_mime string
---@param cfg pi.ImageCompressConfig resolved config
---@param cb fun(out_path: string?, out_mime: string?, err: string?) called on the
---  main loop: out_path non-nil → output temp file (caller reads & unlinks);
---  out_path nil + err nil → silently skipped (disabled/no tool/no-op/unsupported);
---  out_path nil + err string → compression failed (caller warns and falls back).
function M.compress_async(input, input_mime, cfg, cb)
    if not cfg.enable or not M.supported(input_mime) then
        cb(nil)
        return
    end
    local tool = M._detect_tool(cfg.tool)
    if not tool then
        cb(nil)
        return
    end
    local format = M._resolve_format(cfg, tool, input_mime)
    if M._is_noop(cfg, format) then
        cb(nil)
        return
    end

    local output = vim.fn.tempname() .. FORMAT_TO_EXT[format]
    local cmd = M._build_cmd(tool, input, output, {
        max_dimension = cfg.max_dimension or 0,
        quality = cfg.quality or 80,
        format = format,
    })

    local done = vim.schedule_wrap(function(res)
        local stat = vim.uv.fs_stat(output)
        if res.code ~= 0 or not stat or stat.size == 0 then
            vim.uv.fs_unlink(output)
            cb(nil, nil, (res.stderr or ""):gsub("%s+$", ""))
            return
        end
        -- Never attach a "compressed" image that is not smaller than the input.
        local in_stat = vim.uv.fs_stat(input)
        if in_stat and stat.size >= in_stat.size then
            vim.uv.fs_unlink(output)
            cb(nil)
            return
        end
        cb(output, FORMAT_TO_MIME[format])
    end)

    -- vim.system throws when the binary cannot be spawned.
    local ok, err = pcall(vim.system, cmd, { text = true }, done)
    if not ok then
        vim.schedule(function()
            cb(nil, nil, tostring(err))
        end)
    end
end

--- Clear cached tool detection. Test helper.
function M._reset()
    detected_tool = nil
end

return M
