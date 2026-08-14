local Config = require("pi.config")
local WorkspaceBuffers = require("pi.workspace_buffers")

Config.setup({})

describe("workspace buffers", function()
    local start_tab
    local created_buffers

    local function new_buffer(name)
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, name)
        created_buffers[#created_buffers + 1] = buf
        vim.api.nvim_set_current_buf(buf)
        return buf
    end

    local function listed(buf)
        return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
    end

    before_each(function()
        WorkspaceBuffers._reset()
        Config.setup({ workspace_buffers = { enabled = true } })
        start_tab = vim.api.nvim_get_current_tabpage()
        created_buffers = {}
        WorkspaceBuffers.setup()
    end)

    after_each(function()
        WorkspaceBuffers._reset()
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            if tab ~= start_tab and vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                vim.cmd("tabclose!")
            end
        end
        vim.api.nvim_set_current_tabpage(start_tab)
        for _, buf in ipairs(created_buffers) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        Config.setup({})
    end)

    it("keeps buffers already visible in tabs before setup", function()
        WorkspaceBuffers._reset()
        local first = new_buffer("workspace-preexisting-one")
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        local second = new_buffer("workspace-preexisting-two")
        WorkspaceBuffers.setup()

        assert.is_true(WorkspaceBuffers._contains(first, start_tab))
        assert.is_false(WorkspaceBuffers._contains(first, second_tab))
        assert.is_false(WorkspaceBuffers._contains(second, start_tab))
        assert.is_true(WorkspaceBuffers._contains(second, second_tab))

        vim.api.nvim_set_current_tabpage(start_tab)
        assert.is_true(listed(first))
        assert.is_false(listed(second))
        vim.api.nvim_set_current_tabpage(second_tab)
        assert.is_false(listed(first))
        assert.is_true(listed(second))
    end)

    it("keeps a preexisting shared buffer assigned to every visible workspace", function()
        WorkspaceBuffers._reset()
        local shared = new_buffer("workspace-preexisting-shared")
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_buf(shared)
        WorkspaceBuffers.setup()

        assert.is_true(WorkspaceBuffers._contains(shared, start_tab))
        assert.is_true(WorkspaceBuffers._contains(shared, second_tab))
        vim.api.nvim_set_current_tabpage(start_tab)
        assert.is_true(listed(shared))
        vim.api.nvim_set_current_tabpage(second_tab)
        assert.is_true(listed(shared))
    end)

    it("shows only buffers assigned to current workspace", function()
        local first = new_buffer("workspace-one")
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        local second = new_buffer("workspace-two")

        assert.is_false(listed(first))
        assert.is_true(listed(second))
        assert.is_true(WorkspaceBuffers._contains(first, start_tab))
        assert.is_false(WorkspaceBuffers._contains(first, second_tab))
        assert.is_false(WorkspaceBuffers._contains(second, start_tab))
        assert.is_true(WorkspaceBuffers._contains(second, second_tab))
        assert.is_true(vim.tbl_contains(WorkspaceBuffers.list(start_tab), first))

        vim.api.nvim_set_current_tabpage(start_tab)
        assert.is_true(listed(first))
        assert.is_false(listed(second))

        vim.api.nvim_set_current_tabpage(second_tab)
        assert.is_false(listed(first))
        assert.is_true(listed(second))

        vim.api.nvim_set_current_tabpage(start_tab)
        assert.is_true(WorkspaceBuffers._contains(first, start_tab))
        assert.is_false(WorkspaceBuffers._contains(first, second_tab))
        assert.is_false(WorkspaceBuffers._contains(second, start_tab))
        assert.is_true(WorkspaceBuffers._contains(second, second_tab))
    end)

    it("allows one buffer in multiple workspaces when explicitly entered", function()
        local shared = new_buffer("workspace-shared")
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_buf(shared)

        assert.is_true(WorkspaceBuffers._contains(shared, start_tab))
        assert.is_true(WorkspaceBuffers._contains(shared, second_tab))
        vim.api.nvim_set_current_tabpage(start_tab)
        assert.is_true(listed(shared))
        vim.api.nvim_set_current_tabpage(second_tab)
        assert.is_true(listed(shared))
    end)

    it("ignores native unlisted buffers", function()
        local unlisted = vim.api.nvim_create_buf(false, true)
        created_buffers[#created_buffers + 1] = unlisted
        vim.api.nvim_set_current_buf(unlisted)

        assert.is_false(listed(unlisted))
        assert.is_false(WorkspaceBuffers._contains(unlisted, start_tab))
    end)

    it("moves current buffer to another workspace", function()
        local moved = new_buffer("workspace-moved")
        vim.cmd("tabnew")
        local second_tab = vim.api.nvim_get_current_tabpage()
        new_buffer("workspace-second")
        vim.api.nvim_set_current_tabpage(start_tab)
        vim.api.nvim_set_current_buf(moved)

        assert.is_true(WorkspaceBuffers.move_current(2))
        assert.is_false(listed(moved))
        assert.is_false(WorkspaceBuffers._contains(moved, start_tab))
        assert.is_true(WorkspaceBuffers._contains(moved, second_tab))

        vim.api.nvim_set_current_tabpage(second_tab)
        assert.is_true(listed(moved))
    end)

    it("keeps History buffers in their session workspace", function()
        local history = new_buffer("workspace-history")
        vim.b[history].pi_session_id = 1
        vim.cmd("tabnew")
        new_buffer("workspace-other")
        vim.api.nvim_set_current_tabpage(start_tab)
        vim.api.nvim_set_current_buf(history)

        assert.is_false(WorkspaceBuffers.move_current(2))
        assert.is_true(listed(history))
    end)

    it("does not delete buffers when their workspace closes", function()
        local kept = new_buffer("workspace-close")
        vim.cmd("tabnew")
        new_buffer("workspace-survivor")
        vim.cmd("tabclose!")

        assert.is_true(vim.api.nvim_buf_is_valid(kept))
    end)
end)
