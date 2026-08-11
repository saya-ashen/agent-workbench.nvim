local History = require("pi.ui.chat.history")

local TAB = 970

local function chunks_text(chunks)
    local text = ""
    for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
    end
    return text
end

local function history_with_lines(lines)
    local history = History.new(TAB)
    history:_with_modifiable(function()
        vim.api.nvim_buf_set_lines(history:buf(), 0, -1, false, lines)
    end)
    return history
end

describe("history native fold text", function()
    it("adds first prose line to message fold text", function()
        local history = history_with_lines({
            "󰚩 Aug 11 2026, 16:10",
            "",
            "Fixed fold summaries.",
            "More detail.",
        })
        local anchor = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        history._message_blocks = { { anchor = anchor, role = "assistant" } }

        local text = chunks_text(history:_native_foldtext(0, 3))
        assert.is_not_nil(text:find("Fixed fold summaries.", 1, true))
        assert.is_not_nil(text:find("[4 lines]", 1, true))
    end)

    it("adds tool argument summary and completion state", function()
        local history = history_with_lines({
            "󰻂 tool_batch",
            "  output",
            "",
        })
        local header = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        local footer = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 2, 0, {})
        history._tool_blocks.call = {
            icon_extmark = header,
            end_extmark = footer,
            tool_name = "tool_batch",
            tool_input = { calls = { {}, {} } },
            finished = true,
            end_hl_group = "PiToolHeader",
        }

        local text = chunks_text(history:_native_foldtext(0, 2))
        assert.is_not_nil(text:find("2 calls", 1, true))
        assert.is_not_nil(text:find("completed", 1, true))
        assert.is_not_nil(text:find("[3 lines]", 1, true))
    end)

    it("groups consecutive assistant messages into one fold", function()
        local history = history_with_lines({ "user", "", "assistant one", "body", "assistant two", "body" })
        local user = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        local first = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 2, 0, {})
        local second = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 4, 0, {})
        history._message_blocks = {
            { anchor = user, role = "user" },
            { anchor = first, role = "assistant" },
            { anchor = second, role = "assistant" },
        }

        local values = history:_native_fold_values()
        assert.equals(">1", values[3])
        assert.equals(1, values[5])
    end)

    it("creates child folds from structured tool_batch results", function()
        local history = history_with_lines({
            "assistant",
            "󰻂 tool_batch",
            "```text",
            "Batch: 2/2 succeeded",
            "",
            "## 1. read",
            "Status: completed",
            "alpha",
            "",
            "## 2. read",
            "Status: completed",
            "beta",
            "```",
        })
        local assistant = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        history._message_blocks = { { anchor = assistant, role = "assistant" } }
        history:_register_batch_item_folds("batch", {
            details = {
                items = {
                    { toolName = "read", args = { path = "a" }, isError = false },
                    { toolName = "read", args = { path = "b" }, isError = false },
                },
            },
        }, 2, 13)

        local values = history:_native_fold_values()
        assert.equals(">2", values[6])
        assert.equals(">2", values[10])
        local item = history._tool_blocks["batch:batch:1"]
        local text = chunks_text(
            history:_native_foldtext(history:_extmark_row(item.icon_extmark), history:_extmark_row(item.end_extmark))
        )
        assert.is_not_nil(text:find("󰈙  read", 1, true))
        assert.is_not_nil(text:find("a", 1, true))
    end)
end)
