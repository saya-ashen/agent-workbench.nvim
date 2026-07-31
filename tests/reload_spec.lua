-- Unit tests for lua/pi/reload.lua

describe("pi.reload", function()
    local Reload

    --- macOS resolves tempdir symlinks (/tmp → /private/tmp) in buffer names,
    --- while the /tmp literals below are not resolved. Normalize after creating
    --- the file so assertions match the buffer name.
    local function realpath(path)
        return vim.uv.fs_realpath(path) or path
    end

    before_each(function()
        package.loaded["pi.reload"] = nil
        package.loaded["pi.config"] = nil
        Reload = require("pi.reload")
    end)

    after_each(function()
        -- Clean up any test buffers created
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(buf)
            if name:find("pi_reload_test", 1, true) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
        end
    end)

    describe("reload_buffers", function()
        it("reloads an unmodified buffer", function()
            local path = "/tmp/pi_reload_test_a.txt"
            local f = io.open(path, "w")
            f:write("original")
            f:close()
            path = realpath(path)

            vim.cmd("silent edit " .. path)
            local buf = vim.fn.bufnr(path)
            assert.is_true(vim.api.nvim_buf_is_loaded(buf))
            assert.is_false(vim.bo[buf].modified)

            -- Modify file on disk
            f = io.open(path, "w")
            f:write("changed")
            f:close()

            local result = Reload.reload_buffers({ path })
            assert.are.same({ path }, result.reloaded)
            assert.are.same({}, result.skipped)

            -- Buffer content should reflect the new file content
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.are.equal("changed", lines[1])

            os.remove(path)
        end)

        it("skips a modified buffer", function()
            local path = "/tmp/pi_reload_test_b.txt"
            local f = io.open(path, "w")
            f:write("original")
            f:close()
            path = realpath(path)

            vim.cmd("silent edit " .. path)
            local buf = vim.fn.bufnr(path)

            -- Mark buffer as modified (unsaved user changes)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user edit" })
            assert.is_true(vim.bo[buf].modified)

            -- Modify file on disk
            f = io.open(path, "w")
            f:write("changed on disk")
            f:close()

            local result = Reload.reload_buffers({ path })
            assert.are.same({}, result.reloaded)
            assert.are.same({ path }, result.skipped)

            -- Buffer must still hold the user's unsaved content
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.are.equal("user edit", lines[1])

            os.remove(path)
        end)

        it("ignores paths with no loaded buffer", function()
            local result = Reload.reload_buffers({ "/tmp/pi_reload_test_nonexistent.txt" })
            assert.are.same({}, result.reloaded)
            assert.are.same({}, result.skipped)
        end)

        it("matches a buffer whose name resolved a symlink in the reported path", function()
            -- Neovim resolves symlinks in buffer names (/tmp → /private/tmp on
            -- macOS); pi may report the unresolved form. reload_buffers must match
            -- both sides by canonical path and echo the raw path back.
            local raw = "/tmp/pi_reload_test_symlink.txt"
            local f = io.open(raw, "w")
            f:write("original")
            f:close()
            local resolved = realpath(raw)

            vim.cmd("silent edit " .. raw)
            local buf = vim.fn.bufnr(resolved)
            assert.are.equal(resolved, vim.api.nvim_buf_get_name(buf))

            f = io.open(raw, "w")
            f:write("changed")
            f:close()

            local result = Reload.reload_buffers({ raw })
            assert.are.same({ raw }, result.reloaded)
            assert.are.same({}, result.skipped)

            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.are.equal("changed", lines[1])

            os.remove(raw)
        end)

        it("handles multiple paths independently", function()
            local path_a = "/tmp/pi_reload_test_c1.txt"
            local path_b = "/tmp/pi_reload_test_c2.txt"

            for _, p in ipairs({ path_a, path_b }) do
                local f = io.open(p, "w")
                f:write("orig")
                f:close()
                vim.cmd("silent edit " .. p)
            end
            path_a = realpath(path_a)
            path_b = realpath(path_b)

            -- Modify path_a on disk; leave path_b's buffer modified by user
            local f = io.open(path_a, "w")
            f:write("new_a")
            f:close()

            local buf_b = vim.fn.bufnr(path_b)
            vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { "user_b" })

            local result = Reload.reload_buffers({ path_a, path_b })
            assert.are.same({ path_a }, result.reloaded)
            assert.are.same({ path_b }, result.skipped)

            os.remove(path_a)
            os.remove(path_b)
        end)
    end)

    describe("on_file_changed", function()
        it("does nothing when mode is false", function()
            require("pi.config").setup({ reload = { mode = false } })

            local path = "/tmp/pi_reload_test_d.txt"
            local f = io.open(path, "w")
            f:write("original")
            f:close()
            path = realpath(path)
            vim.cmd("silent edit " .. path)

            f = io.open(path, "w")
            f:write("changed")
            f:close()

            Reload.on_file_changed(path)

            local buf = vim.fn.bufnr(path)
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            -- Buffer should NOT have been reloaded
            assert.are.equal("original", lines[1])

            os.remove(path)
        end)

        it("reloads silently when mode is silent", function()
            require("pi.config").setup({ reload = { mode = "silent" } })

            local path = "/tmp/pi_reload_test_e.txt"
            local f = io.open(path, "w")
            f:write("original")
            f:close()
            path = realpath(path)
            vim.cmd("silent edit " .. path)

            f = io.open(path, "w")
            f:write("changed")
            f:close()

            Reload.on_file_changed(path)

            local buf = vim.fn.bufnr(path)
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            assert.are.equal("changed", lines[1])

            os.remove(path)
        end)
    end)
end)
