local History = require("agent-workbench.ui.chat.history")

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

    it("groups consecutive assistant activity messages into one fold", function()
        local history = history_with_lines({ "user", "", "assistant one", "body", "assistant two", "body" })
        local user = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        local first = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 2, 0, {})
        local second = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 4, 0, {})
        history._message_blocks = {
            { anchor = user, role = "user" },
            { anchor = first, role = "assistant", section = "activity" },
            { anchor = second, role = "assistant", section = "activity" },
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

    it("defers native fold window work until replay finishes", function()
        local history = history_with_lines({ "assistant", "tool", "output", "footer" })
        vim.api.nvim_win_set_buf(0, history:buf())
        history:set_win(0)
        local assistant = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 0, 0, {})
        local tool = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 1, 0, {})
        local footer = vim.api.nvim_buf_set_extmark(history:buf(), history:ns(), 3, 0, {})
        history._message_blocks = { { anchor = assistant, role = "assistant", section = "output" } }
        history._tool_blocks.call = {
            icon_extmark = tool,
            end_extmark = footer,
            tool_name = "read",
            foldable = true,
            expanded = false,
            finished = true,
        }
        history._fold_changedtick = nil
        history._fold_values = nil

        local real_win_call = vim.api.nvim_win_call
        local win_calls = 0
        vim.api.nvim_win_call = function(win, callback)
            win_calls = win_calls + 1
            return real_win_call(win, callback)
        end
        local ok, err = pcall(function()
            history._replaying = true
            history:_refresh_native_folds()
            history:_activate_output_fold(assistant, 1, assistant)
            history:_close_active_output_folds()
            assert.are.equal(0, win_calls)

            history._replaying = false
            history:finish_replaying()
            assert.is_true(win_calls > 0)
            assert.are.equal(-1, vim.fn.foldclosed(1), "assistant output stays open")
            assert.are.equal(">2", history:_native_fold_values()[2], "nested tool fold is rebuilt")
        end)
        vim.api.nvim_win_call = real_win_call
        assert.is_true(ok, err)
    end)
end)
