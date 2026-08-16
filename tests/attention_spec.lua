local Attention = require("agent-workbench.attention")

local function session(tab)
    return {
        id = 1,
        tab = tab,
        attention = { pending = {} },
        rpc = {
            is_running = function()
                return true
            end,
        },
        chat = {
            has_prompt_focus = function()
                return false
            end,
            has_prompt_request = function()
                return false
            end,
            has_draft = function()
                return true
            end,
        },
    }
end

describe("cross-tab attention", function()
    local original_manager
    local start_tab
    local second_tab

    before_each(function()
        start_tab = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        second_tab = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_tabpage(start_tab)
        original_manager = package.loaded["agent-workbench.sessions.manager"]
    end)

    after_each(function()
        package.loaded["agent-workbench.sessions.manager"] = original_manager
        if vim.api.nvim_tabpage_is_valid(second_tab) then
            vim.api.nvim_set_current_tabpage(second_tab)
            vim.cmd("tabclose!")
        end
        vim.api.nvim_set_current_tabpage(start_tab)
    end)

    it("switches to valid owning tab before activation", function()
        local owner = session(second_tab)
        local activated_tab
        package.loaded["agent-workbench.sessions.manager"] = {
            list = function()
                return { owner }
            end,
            get = function()
                return nil
            end,
            get_for_tab = function()
                return nil
            end,
            activate = function()
                activated_tab = vim.api.nvim_get_current_tabpage()
            end,
            is_current = function()
                return false
            end,
        }
        assert.is_true(Attention.present(owner, { type = "extension_ui_request", id = "1", method = "input" }))
        owner.attention.pending[1].open = function()
            return true
        end

        assert.is_true(Attention.open_next())
        assert.are.equal(second_tab, activated_tab)
    end)

    it("keeps current tab when owning tab is invalid", function()
        local owner = session(second_tab)
        vim.api.nvim_set_current_tabpage(second_tab)
        vim.cmd("tabclose!")
        package.loaded["agent-workbench.sessions.manager"] = {
            list = function()
                return { owner }
            end,
            get = function()
                return nil
            end,
            get_for_tab = function()
                return nil
            end,
            activate = function() end,
            is_current = function()
                return false
            end,
        }
        assert.is_true(Attention.present(owner, { type = "extension_ui_request", id = "2", method = "input" }))
        owner.attention.pending[1].open = function()
            return true
        end

        assert.is_true(Attention.open_next())
        assert.are.equal(start_tab, vim.api.nvim_get_current_tabpage())
    end)
end)
