local Config = require("agent-workbench.config")
local Keys = require("agent-workbench.keys")
local RecommendedKeymaps = require("agent-workbench.recommended_keymaps")

local SUFFIXES = { "a", "c", "r", "m", "d", "t", "w", "W", "e" }
local FIXED_KEYS = { "<M-h>", "<M-l>", "<M-j>", "<M-k>" }

---@param lhs string
---@param mode string
---@return table?
local function global_map(lhs, mode)
    local normalized = Keys.normalize_lhs(lhs)
    for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
        if Keys.normalize_lhs(mapping.lhs) == normalized then
            return mapping
        end
    end
    return nil
end

---@param prefix string
local function clear_test_maps(prefix)
    for _, suffix in ipairs(SUFFIXES) do
        for _, mode in ipairs({ "n", "x" }) do
            pcall(vim.keymap.del, mode, prefix .. suffix)
        end
    end
    for _, lhs in ipairs(FIXED_KEYS) do
        pcall(vim.keymap.del, "n", lhs)
    end
end

describe("recommended global keymaps", function()
    local original_leader
    local original_notify
    local notifications

    before_each(function()
        original_leader = vim.g.mapleader
        original_notify = vim.notify
        vim.g.mapleader = ","
        notifications = {}
        vim.notify = function(message, level)
            notifications[#notifications + 1] = { message = message, level = level }
        end
        RecommendedKeymaps._reset()
        clear_test_maps(",a")
        clear_test_maps(",z")
        Config.setup({})
    end)

    after_each(function()
        RecommendedKeymaps._reset()
        clear_test_maps(",a")
        clear_test_maps(",z")
        Config.setup({})
        vim.notify = original_notify
        vim.g.mapleader = original_leader
    end)

    it("keeps the recommended preset disabled by default", function()
        assert.is_false(Config.options.keymaps.preset)
        assert.are.equal("<Leader>a", Config.options.keymaps.prefix)

        RecommendedKeymaps.setup()

        assert.is_nil(global_map(",aa", "n"))
    end)

    it("installs the complete recommended preset with descriptions and modes", function()
        Config.setup({ keymaps = { preset = "recommended" } })
        RecommendedKeymaps.setup()

        for _, suffix in ipairs(SUFFIXES) do
            local mapping = global_map(",a" .. suffix, "n")
            assert.is_not_nil(mapping, "missing Normal mapping for suffix " .. suffix)
            assert.is_truthy(mapping.desc:find("Agent Workbench", 1, true))
        end
        for _, lhs in ipairs(FIXED_KEYS) do
            local mapping = global_map(lhs, "n")
            assert.is_not_nil(mapping, "missing Normal mapping for " .. lhs)
            assert.is_truthy(mapping.desc:find("Agent Workbench", 1, true))
        end
        assert.are.equal("Agent Workbench: create new session", global_map(",aa", "n").desc)
        assert.is_not_nil(global_map(",am", "x"))
        assert.is_nil(global_map(",aa", "x"))
    end)

    it("dispatches every recommended mapping through the public interface", function()
        local calls = {}
        local original_agent_workbench = package.loaded["agent-workbench"]
        package.loaded["agent-workbench"] = {
            new_session = function()
                calls[#calls + 1] = "new_session"
            end,
            continue_session = function()
                calls[#calls + 1] = "continue"
            end,
            resume_session = function()
                calls[#calls + 1] = "resume"
            end,
            send_mention = function()
                calls[#calls + 1] = "mention"
            end,
            diff_review = function()
                calls[#calls + 1] = "diff"
            end,
            attention = function()
                calls[#calls + 1] = "attention"
            end,
            workspaces = function()
                calls[#calls + 1] = "workspaces"
            end,
            new_workspace = function()
                calls[#calls + 1] = "create_workspace"
            end,
            workspace_sidebar = function()
                calls[#calls + 1] = "explorer"
            end,
        }

        local ok, err = pcall(function()
            Config.setup({ keymaps = { preset = "recommended" } })
            RecommendedKeymaps.setup()
            for _, suffix in ipairs(SUFFIXES) do
                global_map(",a" .. suffix, "n").callback()
            end
        end)
        package.loaded["agent-workbench"] = original_agent_workbench

        assert.is_true(ok, err)
        assert.are.same({
            "new_session",
            "continue",
            "resume",
            "mention",
            "diff",
            "attention",
            "workspaces",
            "create_workspace",
            "explorer",
        }, calls)
    end)

    it("creates a new session through the configured leader sequence", function()
        local called = false
        local original_agent_workbench = package.loaded["agent-workbench"]
        package.loaded["agent-workbench"] = {
            new_session = function()
                called = true
            end,
        }

        local ok, err = pcall(function()
            Config.setup({ keymaps = { preset = "recommended" } })
            RecommendedKeymaps.setup()
            local keys = vim.api.nvim_replace_termcodes(",aa", true, false, true)
            vim.api.nvim_feedkeys(keys, "xt", false)
            assert.is_true(vim.wait(100, function()
                return called
            end))
        end)
        package.loaded["agent-workbench"] = original_agent_workbench

        assert.is_true(ok, err)
    end)

    it("fires the workspace picker through the configured leader sequence", function()
        local called = false
        local original_agent_workbench = package.loaded["agent-workbench"]
        package.loaded["agent-workbench"] = {
            workspaces = function()
                called = true
            end,
        }

        local ok, err = pcall(function()
            Config.setup({ keymaps = { preset = "recommended" } })
            RecommendedKeymaps.setup()
            local keys = vim.api.nvim_replace_termcodes(",aw", true, false, true)
            vim.api.nvim_feedkeys(keys, "xt", false)
            assert.is_true(vim.wait(100, function()
                return called
            end))
        end)
        package.loaded["agent-workbench"] = original_agent_workbench

        assert.is_true(ok, err)
    end)

    it("cycles listed buffers and workspace tabs", function()
        local initial_tab = vim.api.nvim_get_current_tabpage()
        local initial_buf = vim.api.nvim_get_current_buf()
        local listed = {}
        local first
        local second
        local extra_tab

        local ok, err = pcall(function()
            Config.setup({ keymaps = { preset = "recommended" } })
            RecommendedKeymaps.setup()

            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
                    listed[#listed + 1] = buf
                    vim.bo[buf].buflisted = false
                end
            end
            first = vim.api.nvim_create_buf(true, true)
            second = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_set_current_buf(first)

            global_map("<M-l>", "n").callback()
            assert.are.equal(second, vim.api.nvim_get_current_buf())
            global_map("<M-h>", "n").callback()
            assert.are.equal(first, vim.api.nvim_get_current_buf())

            vim.cmd("tab split")
            extra_tab = vim.api.nvim_get_current_tabpage()
            vim.api.nvim_set_current_tabpage(initial_tab)
            global_map("<M-j>", "n").callback()
            assert.are.equal(extra_tab, vim.api.nvim_get_current_tabpage())
            global_map("<M-k>", "n").callback()
            assert.are.equal(initial_tab, vim.api.nvim_get_current_tabpage())
        end)

        if extra_tab and vim.api.nvim_tabpage_is_valid(extra_tab) then
            vim.api.nvim_set_current_tabpage(extra_tab)
            vim.cmd("tabclose!")
        end
        if vim.api.nvim_tabpage_is_valid(initial_tab) then
            vim.api.nvim_set_current_tabpage(initial_tab)
        end
        for _, buf in ipairs(listed) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.bo[buf].buflisted = true
            end
        end
        if vim.api.nvim_buf_is_valid(initial_buf) then
            vim.api.nvim_set_current_buf(initial_buf)
        end
        for _, buf in ipairs({ first, second }) do
            if buf and vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end

        assert.is_true(ok, err)
    end)

    it("uses a custom prefix without moving fixed Alt navigation", function()
        Config.setup({ keymaps = { preset = "recommended", prefix = "<Leader>z" } })
        RecommendedKeymaps.setup()

        assert.is_nil(global_map(",aa", "n"))
        assert.is_not_nil(global_map(",za", "n"))
        assert.is_not_nil(global_map(",zw", "n"))
        assert.is_not_nil(global_map("<M-j>", "n"))
    end)

    it("skips existing global mappings and warns without overriding them", function()
        vim.keymap.set("n", "<Leader>aa", function() end, { desc = "Existing mapping" })
        vim.keymap.set("n", "<M-h>", function() end, { desc = "Existing Alt mapping" })
        Config.setup({ keymaps = { preset = "recommended" } })
        RecommendedKeymaps.setup()

        assert.are.equal("Existing mapping", global_map(",aa", "n").desc)
        assert.are.equal("Existing Alt mapping", global_map("<M-h>", "n").desc)
        assert.is_not_nil(global_map(",ac", "n"))
        assert.are.equal(1, #notifications)
        assert.is_truthy(notifications[1].message:find("<Leader>aa", 1, true))
        assert.is_truthy(notifications[1].message:find("<M-h>", 1, true))
        assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    end)

    it("does not remove a user mapping that replaced an installed mapping", function()
        Config.setup({ keymaps = { preset = "recommended" } })
        RecommendedKeymaps.setup()
        vim.keymap.set("n", "<Leader>aa", function() end, { desc = "User replacement" })

        Config.setup({ keymaps = { preset = false } })
        RecommendedKeymaps.setup()

        assert.are.equal("User replacement", global_map(",aa", "n").desc)
        assert.is_nil(global_map(",ac", "n"))
        assert.is_nil(global_map("<M-l>", "n"))
    end)

    it("rejects invalid preset and prefix values", function()
        Config.setup({ keymaps = { preset = "unknown" } })
        assert.has_error(function()
            RecommendedKeymaps.setup()
        end, 'Agent Workbench: keymaps.preset must be false or "recommended"')

        Config.setup({ keymaps = { preset = "recommended", prefix = "" } })
        assert.has_error(function()
            RecommendedKeymaps.setup()
        end, "Agent Workbench: keymaps.prefix must be a non-empty string")
    end)
end)
