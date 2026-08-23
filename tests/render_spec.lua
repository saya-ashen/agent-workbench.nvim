local Config = require("agent-workbench.config")
local Render = require("agent-workbench.ui.render")

local function markdown_config(extra)
    return vim.tbl_deep_extend("force", {
        markdown = {
            enabled = true,
            debounce_ms = 1,
            features = {},
            symbols = {},
        },
    }, extra or {})
end

local function parser_stub(on_parse)
    return {
        init = function(buf)
            if on_parse then
                on_parse(buf)
            end
            return { markdown = {}, markdown_inline = {} }, {}
        end,
    }
end

local function details(buf)
    local marks = vim.api.nvim_buf_get_extmarks(buf, Render._namespace, 0, -1, { details = true })
    local out = {}
    for _, mark in ipairs(marks) do
        out[#out + 1] = mark[4]
    end
    return out
end

local function has_hl(buf, expected)
    for _, detail in ipairs(details(buf)) do
        if detail.hl_group == expected then
            return true
        end
    end
    return false
end

describe("message-level Markdown rendering", function()
    local original_parser
    local original_preload
    local original_notify
    local original_buf
    local buffers

    before_each(function()
        original_parser = package.loaded["markview.parser"]
        original_preload = package.preload["markview.parser"]
        original_notify = vim.notify
        original_buf = vim.api.nvim_get_current_buf()
        buffers = {}
        Config.options.render = markdown_config()
        package.loaded["markview.parser"] = parser_stub()
        Render._reset()
    end)

    after_each(function()
        if original_buf and vim.api.nvim_buf_is_valid(original_buf) then
            vim.api.nvim_win_set_buf(0, original_buf)
        end
        for _, buf in ipairs(buffers) do
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
        package.loaded["markview.parser"] = original_parser
        package.preload["markview.parser"] = original_preload
        vim.notify = original_notify
        Config.options.render = markdown_config()
        Render._reset()
    end)

    local function new_buffer(lines)
        local buf = vim.api.nvim_create_buf(true, true)
        buffers[#buffers + 1] = buf
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        Render.attach_history(buf)
        return buf
    end

    it("uses the isolated renderer by default and raw mode when disabled", function()
        assert.are.equal("markdown", Render.engine())
        Config.options.render.markdown.enabled = false
        assert.are.equal("raw", Render.engine())
    end)

    it("accepts legacy markview but rejects removed engines", function()
        Config.options.render.engine = "markview"
        assert.are.equal("markdown", Render.engine())
        Config.options.render.engine = "builtin"
        assert.are.equal("raw", Render.engine())
        Config.options.render.engine = "render-markdown"
        assert.are.equal("raw", Render.engine())
    end)

    it("applies Tree-sitter captures to one block without changing its text", function()
        local source = "# Heading **bold**"
        local buf = new_buffer({ source })
        vim.api.nvim_win_set_buf(0, buf)
        local block = assert(Render.start_block(buf, "assistant", 0, source, 0, true))
        assert.is_true(block.complete)
        assert.is_true(has_hl(buf, "AgentWorkbenchMarkdownStrong"))
        assert.are.same({ source }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end)

    it("keeps an unclosed fence in one block from poisoning the next heading", function()
        local buf = new_buffer({ "```lua", "local x = 1", "### Next" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.start_block(buf, "assistant", 0, "```lua\nlocal x = 1", 0, true)
        Render.start_block(buf, "assistant", 2, "### Next", 0, true)
        assert.is_true(has_hl(buf, "AgentWorkbenchMarkdownHeading3"))
    end)

    it("offsets user-message captures past the two-column body prefix", function()
        local buf = new_buffer({ "  **bold**" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.start_block(buf, "user", 0, "**bold**", 2, true)
        local found = false
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Render._namespace, 0, -1, { details = true })) do
            if mark[4].hl_group == "AgentWorkbenchMarkdownStrong" then
                found = mark[3] == 2
            end
        end
        assert.is_true(found)
    end)

    it("translates multiline user capture start and end columns", function()
        local source = "[multi\nline](url)"
        local buf = new_buffer({ "  [multi", "  line](url)" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.start_block(buf, "user", 0, source, 2, true)
        local found = false
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Render._namespace, 0, -1, { details = true })) do
            local detail = mark[4]
            if detail.hl_group == "AgentWorkbenchMarkdownLink" and mark[2] == 0 and mark[3] == 3 then
                found = detail.end_row == 1 and detail.end_col == 6
            end
        end
        assert.is_true(found)
    end)

    it("coalesces streamed recompiles and renders the final source", function()
        local parses = 0
        package.loaded["markview.parser"] = parser_stub(function()
            parses = parses + 1
        end)
        local buf = new_buffer({ "" })
        vim.api.nvim_win_set_buf(0, buf)
        local block = assert(Render.start_block(buf, "assistant", 0, "**bo", 0, false))
        Render.append_block(block, "ld")
        Render.append_block(block, "**")
        assert.is_true(vim.wait(100, function()
            return parses == 1
        end))
        assert.is_true(has_hl(buf, "AgentWorkbenchMarkdownStrong"))
    end)

    it("defers replay blocks until resume and compiles each dirty block once", function()
        local parses = 0
        package.loaded["markview.parser"] = parser_stub(function()
            parses = parses + 1
        end)
        local buf = new_buffer({ "# one", "# two" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.pause_history(buf)
        Render.start_block(buf, "user", 0, "# one", 0, true)
        Render.start_block(buf, "user", 1, "# two", 0, true)
        assert.are.equal(0, parses)
        Render.resume_history(buf)
        assert.is_true(vim.wait(100, function()
            return parses == 2
        end))
    end)

    it("reports a missing parser once and preserves raw text", function()
        package.loaded["markview.parser"] = nil
        package.preload["markview.parser"] = function()
            error("missing")
        end
        local notifications = 0
        vim.notify = function(message)
            if message:find("Markview parser is unavailable", 1, true) then
                notifications = notifications + 1
            end
        end
        Render._reset()
        local buf = new_buffer({ "# raw", "# still raw" })
        Render.start_block(buf, "assistant", 0, "# raw", 0, true)
        Render.start_block(buf, "assistant", 1, "# still raw", 0, true)
        assert.are.equal(1, notifications)
        assert.are.same({ "# raw", "# still raw" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        assert.are.equal(0, #Render._states()[buf].blocks)
    end)

    it("recompiles only visible width-dependent blocks after a width change", function()
        local parses = 0
        package.loaded["markview.parser"] = {
            init = function(buf)
                parses = parses + 1
                local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
                local markdown = {}
                if line == "---" then
                    markdown[1] = {
                        class = "markdown_hr",
                        range = { row_start = 0, col_start = 0, row_end = 1, col_end = 0 },
                    }
                end
                return { markdown = markdown, markdown_inline = {} }, {}
            end,
        }
        local buf = new_buffer({ "---", "plain" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.start_block(buf, "assistant", 0, "---", 0, true)
        Render.start_block(buf, "assistant", 1, "plain", 0, true)
        assert.are.equal(2, parses)
        local original_columns = vim.o.columns
        vim.o.columns = original_columns + 10
        Render.configure_history_window(buf, 0)
        assert.is_true(vim.wait(100, function()
            return parses == 3
        end))
        vim.o.columns = original_columns
    end)

    it("keeps the anchor but removes partial decorations after an apply failure", function()
        local buf = new_buffer({ "**bold**" })
        vim.api.nvim_win_set_buf(0, buf)
        local original_set_extmark = vim.api.nvim_buf_set_extmark
        local calls = 0
        local notified = 0
        vim.notify = function(message)
            if message:find("Markdown decoration failed", 1, true) then
                notified = notified + 1
            end
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.api.nvim_buf_set_extmark = function(...)
            calls = calls + 1
            if calls == 2 then
                error("apply boom")
            end
            return original_set_extmark(...)
        end
        local ok, block = pcall(Render.start_block, buf, "assistant", 0, "**bold**", 0, true)
        vim.api.nvim_buf_set_extmark = original_set_extmark
        assert.is_true(ok)
        assert.is_not_nil(block)
        assert.are.equal(0, #block.decoration_ids)
        assert.is_not_nil(vim.api.nvim_buf_get_extmark_by_id(buf, Render._namespace, block.anchor, {})[1])
        assert.are.equal(1, notified)
    end)

    it("configures History windows for stable conceal without Markview callbacks", function()
        local buf = new_buffer({ "text" })
        vim.api.nvim_win_set_buf(0, buf)
        Render.configure_history_window(buf, 0)
        assert.are.equal(2, vim.wo[0].conceallevel)
        assert.are.equal("nvic", vim.wo[0].concealcursor)
    end)
end)
