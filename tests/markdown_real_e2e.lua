-- Real integration check: packaged Markview parser + Neovim Markdown queries.
-- Run with `make markdown-e2e` (the dev-shell demo nvim supplies Markview).

local function fail(message)
    io.stderr:write("markdown-e2e: " .. message .. "\n")
    vim.cmd("cq 1")
end

local ok, err = xpcall(function()
    local markview_ok, parser = pcall(require, "markview.parser")
    assert(markview_ok and type(parser.init) == "function", "real markview.parser.init is unavailable")

    local Config = require("agent-workbench.config")
    Config.setup({ render = { markdown = { debounce_ms = 1 } } })
    require("agent-workbench.ui.highlights").setup()
    local History = require("agent-workbench.ui.chat.history")
    local Render = require("agent-workbench.ui.render")

    local history = History.new(1700)
    vim.api.nvim_win_set_buf(0, history:buf())
    history:set_win(0)

    history:on_agent_start(1, "output", false)
    history:on_text_delta("```lua\nlocal value = 42") -- intentionally unclosed
    history:on_agent_end()
    vim.wait(80)

    history:on_tool_start("bash", "tool-1", { command = "printf test" })
    vim.wait(20)
    history:on_tool_end(
        "bash",
        "tool-1",
        { content = { { type = "text", text = "  ```sh\n### tool-only\n  ````" } } },
        false
    )
    vim.wait(40)

    history:on_agent_start(2, "output", false)
    history:on_text_delta("Title\n=====\n\n### Next **bold** [link](https://example.com)\n\n---")
    history:on_agent_end()
    assert(vim.wait(300, function()
        return #history._markdown_blocks == 2 and history._markdown_blocks[2].complete
    end))

    local source = table.concat(vim.api.nvim_buf_get_lines(history:buf(), 0, -1, false), "\n")
    assert(source:find("```lua", 1, true), "raw unclosed fence was changed")
    assert(source:find("```sh", 1, true), "tool fence is missing from raw tool output")
    assert(source:find("[link](https://example.com)", 1, true), "raw link was changed")

    local groups = {}
    local concealed_link_destination = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(history:buf(), Render._namespace, 0, -1, { details = true })) do
        local detail = mark[4]
        if detail.hl_group then
            groups[detail.hl_group] = true
        end
        if detail.conceal == "" then
            local row = mark[2]
            local line = vim.api.nvim_buf_get_lines(history:buf(), row, row + 1, false)[1] or ""
            local end_col = detail.end_col or mark[3]
            if line:sub(mark[3] + 1, end_col):find("https://example.com", 1, true) then
                concealed_link_destination = true
            end
        end
    end
    assert(groups["@keyword.lua"], "real fenced Lua injection did not produce @keyword.lua")
    assert(groups["AgentWorkbenchMarkdownHeading1"], "real Setext heading was not rendered")
    assert(groups["AgentWorkbenchMarkdownHeading3"], "message after unclosed fence was not independently rendered")
    assert(groups["AgentWorkbenchMarkdownStrong"], "real strong-emphasis capture was not rendered")
    assert(concealed_link_destination, "real link destination was not concealed")

    local tool_row
    for row, line in ipairs(vim.api.nvim_buf_get_lines(history:buf(), 0, -1, false)) do
        if line == "### tool-only" then
            tool_row = row - 1
            break
        end
    end
    assert(tool_row, "tool output missing")
    local tool_marks = vim.api.nvim_buf_get_extmarks(
        history:buf(),
        Render._namespace,
        { tool_row, 0 },
        { tool_row, -1 },
        { details = true }
    )
    assert(#tool_marks == 0, "tool output received Markdown decorations")

    print("markdown-e2e: OK (real Markview parser, injections, isolation, raw source)")
end, debug.traceback)

if not ok then
    fail(err)
else
    vim.cmd("qa!")
end
