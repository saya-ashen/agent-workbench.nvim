local Config = require("pi.config")
local Diff = require("pi.ui.diff")

Config.setup({})

describe("pre-execution diff write failure", function()
    local original_write
    local original_manager
    local path

    before_each(function()
        original_write = Diff._write_file
        original_manager = package.loaded["pi.sessions.manager"]
        package.loaded["pi.sessions.manager"] = {
            get = function()
                return nil
            end,
        }
        path = vim.fn.tempname()
        vim.fn.writefile({ "old" }, path)
    end)

    after_each(function()
        Diff._write_file = original_write
        package.loaded["pi.sessions.manager"] = original_manager
        vim.fn.delete(path)
        while #vim.api.nvim_list_tabpages() > 1 do
            vim.cmd("tabclose!")
        end
    end)

    it("keeps review open and does not accept when writing fails", function()
        local results = {}
        Diff.open({
            prompt = "write",
            toolName = "write",
            toolInput = { path = path, content = "new\n" },
        }, function(result)
            results[#results + 1] = result
        end)
        local review_tab = vim.api.nvim_get_current_tabpage()
        local proposed_buf = vim.api.nvim_get_current_buf()
        Diff._write_file = function()
            return false
        end

        vim.api.nvim_buf_call(proposed_buf, function()
            vim.cmd("write")
        end)

        assert.is_true(vim.api.nvim_tabpage_is_valid(review_tab))
        assert.are.same({}, results)
        assert.are.same({ "old" }, vim.fn.readfile(path))
    end)
end)
