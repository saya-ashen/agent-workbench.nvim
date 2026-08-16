local Compat = require("pi.compat")
local Cli = require("pi.cli")
local Config = require("pi.config")

local M = {}

---@param bin string
---@return string? version
---@return string? err
local function get_pi_version(bin)
    local output = vim.fn.system({ bin, "--version" })
    if vim.v.shell_error ~= 0 then
        return nil, "failed to run `" .. bin .. " --version`: " .. vim.trim(output)
    end

    local version = Compat.extract_version(output)
    if not version then
        return nil, "could not parse version from `" .. vim.trim(output) .. "`"
    end

    return version, nil
end

--- Check whether a treesitter parser is available.
---@param lang string
---@return boolean
local function has_ts_parser(lang)
    local ok = pcall(vim.treesitter.language.inspect, lang)
    return ok
end

M.check = function()
    vim.health.start("pi.nvim")

    -- ── Neovim version ────────────────────────────────────────────────
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error("Neovim >= 0.10 is required", {
            "Upgrade Neovim to 0.10 or newer",
        })
    end

    -- ── pi executable and version ─────────────────────────────────────
    local bin = Cli.bin()
    local bin_found = vim.fn.executable(bin) == 1
    if bin_found then
        vim.health.ok("`" .. bin .. "` executable found")

        local version, err = get_pi_version(bin)
        if not version then
            vim.health.warn("Could not determine pi version: " .. (err or "unknown error"))
        else
            local cmp_min = Compat.compare_versions(version, Compat.min_supported)
            local cmp_validated = Compat.compare_versions(version, Compat.validated)

            if cmp_min == nil or cmp_validated == nil then
                vim.health.warn(
                    "Could not compare pi version `"
                        .. version
                        .. "` against supported range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            elseif cmp_min < 0 then
                vim.health.error(
                    "pi version `" .. version .. "` is older than minimum supported `" .. Compat.min_supported .. "`"
                )
            elseif cmp_validated > 0 then
                vim.health.warn(
                    "pi version `"
                        .. version
                        .. "` is newer than last validated `"
                        .. Compat.validated
                        .. "` (expected to work, but not validated yet)"
                )
            else
                vim.health.ok(
                    "pi version `"
                        .. version
                        .. "` is within supported/validated range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            end
        end
    else
        vim.health.error("`" .. bin .. "` executable not found in PATH", {
            "Install pi from https://pi.dev",
        })
    end

    -- ── Treesitter parsers ────────────────────────────────────────────
    if has_ts_parser("markdown") then
        vim.health.ok("treesitter `markdown` parser found")
    else
        vim.health.info("treesitter `markdown` parser not found (chat history highlighting will be limited)")
    end
    if has_ts_parser("markdown_inline") then
        vim.health.ok("treesitter `markdown_inline` parser found")
    else
        vim.health.info("treesitter `markdown_inline` parser not found (inline markdown highlighting will be limited)")
    end

    -- ── Optional plugins ──────────────────────────────────────────────
    if pcall(require, "img-clip") then
        vim.health.ok("img-clip.nvim found (clipboard image paste)")
    else
        vim.health.info("img-clip.nvim not found (`:PiPasteImage` and clipboard paste interception unavailable)")
    end

    local render_engine = Config.options.render and Config.options.render.engine or "builtin"
    if pcall(require, "markview") then
        vim.health.ok("markview.nvim found")
    elseif render_engine == "markview" then
        vim.health.warn('markview.nvim not found but `render.engine = "markview"` is set', {
            'Install markview.nvim or set `render.engine = "builtin"`',
        })
    else
        vim.health.info('markview.nvim not found (optional, only needed for `render.engine = "markview"`)')
    end

    if pcall(require, "render-markdown") then
        vim.health.ok("render-markdown.nvim found (legacy renderer)")
    elseif render_engine == "render-markdown" then
        vim.health.warn('render-markdown.nvim not found but `render.engine = "render-markdown"` is set', {
            'Install render-markdown.nvim, use markview, or set `render.engine = "builtin"`',
        })
    end

    if pcall(require, "blink.cmp") then
        vim.health.ok("blink.cmp found (prompt completion)")
    else
        vim.health.info("blink.cmp not found (built-in automatic prompt completion is active)")
    end

    -- ── Bundled tree extension ────────────────────────────────────────
    local tree_cfg = Config.options.tree or {}
    if tree_cfg.enabled ~= false then
        local tree_path = Cli.tree_extension_path()
        if vim.uv.fs_stat(tree_path) then
            vim.health.ok("bundled tree extension found (`:PiTree`)")
        else
            vim.health.warn("bundled tree extension not found at " .. tree_path, {
                "Reinstall Agent Workbench or set `tree = { enabled = false }` to disable :PiTree",
            })
        end
    end

    -- ── Image compression tools ───────────────────────────────────────
    local compress_cfg = Config.options.prompt and Config.options.prompt.image_compress or {}
    if compress_cfg.enable ~= false then
        local ImageCompress = require("pi.image_compress")
        local configured = compress_cfg.tool or "auto"
        local tool = ImageCompress._detect_tool(configured)
        if tool then
            vim.health.ok("image compression tool found: `" .. tool .. "`")
        elseif configured ~= "auto" then
            vim.health.warn("configured image compression tool `" .. configured .. "` not found in PATH", {
                "Install " .. configured .. ' or set `prompt.image_compress.tool = "auto"`',
            })
        else
            vim.health.info("no image compression tool found (sips/magick/ffmpeg); images will be sent uncompressed")
        end
    end
end

return M
