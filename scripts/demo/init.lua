local repo = assert(vim.env.AGENT_WORKBENCH_REPO or vim.fn.getcwd())

vim.opt.runtimepath:prepend(repo)
vim.opt.packpath:prepend(repo)
vim.opt.termguicolors = true
vim.opt.laststatus = 3
vim.opt.showtabline = 2
vim.opt.cmdheight = 1

local ok, catppuccin = pcall(require, "catppuccin")
if ok then
    catppuccin.setup({
        flavour = "mocha",
        integrations = { lualine = true },
    })
    vim.cmd.colorscheme("catppuccin-mocha")
else
    vim.cmd.colorscheme("habamax")
end

local ok_lualine, lualine = pcall(require, "lualine")
if ok_lualine then
    lualine.setup({
        options = {
            globalstatus = true,
            theme = "catppuccin",
            component_separators = "|",
            section_separators = "",
        },
        sections = {
            lualine_a = { "mode" },
            lualine_b = { "branch" },
            lualine_c = { "filename" },
            lualine_x = { "filetype" },
            lualine_y = { "progress" },
            lualine_z = { "location" },
        },
    })
end

require("agent-workbench").setup({
    auto_start_session = false,
    layout = { default = "buffer" },
    workspace_bar = { show = "always", show_index = true },
    sessions_list = { mode = "side", position = "right", width = 38 },
    render = { engine = "markview" },
    prompt = { draft = { enabled = false } },
})

vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        vim.schedule(function()
            local scenario = assert(vim.env.AGENT_WORKBENCH_DEMO, "AGENT_WORKBENCH_DEMO is required")
            local demo = dofile(repo .. "/scripts/demo/scenario.lua")
            assert(demo[scenario], "unknown demo scenario: " .. scenario)()
        end)
    end,
})
