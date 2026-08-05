-- Dialog select/confirm render through vim.ui.select (issue #59).
--
-- All list pickers (thinking level, model, diff review notes, extension
-- select/confirm) were unified on vim.ui.select so rendering, filtering,
-- and keymaps follow the user's picker backend. Dialog.select is now a thin
-- wrapper; these specs pin its contract: prompt/kind/options passthrough,
-- empty-option short-circuit, message folding, and confirm's Yes/No mapping.

local Dialog = require("pi.ui.dialog")

--- Install a vim.ui.select stub that records calls and resolves via fn.
---@return { calls: table[], answer: fun(choice: string?) }
local function stub_select()
    local calls = {}
    local pending = nil ---@type fun(choice: string?)?
    local original = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
        calls[#calls + 1] = { items = items, opts = opts, on_choice = on_choice }
        pending = on_choice
    end
    return {
        calls = calls,
        answer = function(choice)
            local cb = pending
            pending = nil
            if cb then
                cb(choice)
            end
        end,
        restore = function()
            vim.ui.select = original
        end,
    }
end

describe("Dialog.select", function()
    it("passes options, prompt, and kind to vim.ui.select", function()
        local stub = stub_select()
        local got
        Dialog.select(
            { title = "Thinking level", options = { "off", "high" }, kind = "pi-thinking-level" },
            function(choice)
                got = choice
            end
        )

        assert.equal(1, #stub.calls)
        local call = stub.calls[1]
        assert.same({ "off", "high" }, call.items)
        assert.equal("Thinking level", call.opts.prompt)
        assert.equal("pi-thinking-level", call.opts.kind)

        stub.answer("high")
        assert.equal("high", got)
        stub.restore()
    end)

    it("defaults kind to pi-select", function()
        local stub = stub_select()
        Dialog.select({ title = "Pick", options = { "a" } }, function() end)
        assert.equal("pi-select", stub.calls[1].opts.kind)
        stub.restore()
    end)

    it("folds message into the prompt on one line", function()
        local stub = stub_select()
        Dialog.select({ title = "Select", message = "line one\nline  two", options = { "a" } }, function() end)
        assert.equal("Select: line one line two", stub.calls[1].opts.prompt)
        stub.restore()
    end)

    it("short-circuits to callback(nil) without opening a picker for empty options", function()
        local stub = stub_select()
        local got = "unset"
        Dialog.select({ title = "Empty", options = {} }, function(choice)
            got = choice
        end)
        assert.is_nil(got)
        assert.equal(0, #stub.calls)
        stub.restore()
    end)

    it("propagates cancellation as nil", function()
        local stub = stub_select()
        local got = "unset"
        Dialog.select({ title = "Pick", options = { "a" } }, function(choice)
            got = choice
        end)
        stub.answer(nil)
        assert.is_nil(got)
        stub.restore()
    end)
end)

describe("Dialog.confirm", function()
    it("renders Yes/No through vim.ui.select with kind pi-confirm", function()
        local stub = stub_select()
        Dialog.confirm({ title = "Sure?", message = "details" }, function() end)
        assert.equal(1, #stub.calls)
        local call = stub.calls[1]
        assert.same({ "Yes", "No" }, call.items)
        assert.equal("Sure?: details", call.opts.prompt)
        assert.equal("pi-confirm", call.opts.kind)
        stub.restore()
    end)

    it("maps Yes to true and everything else to false", function()
        local stub = stub_select()
        local got
        Dialog.confirm({ title = "Sure?" }, function(confirmed)
            got = confirmed
        end)
        stub.answer("Yes")
        assert.is_true(got)

        Dialog.confirm({ title = "Sure?" }, function(confirmed)
            got = confirmed
        end)
        stub.answer("No")
        assert.is_false(got)

        Dialog.confirm({ title = "Sure?" }, function(confirmed)
            got = confirmed
        end)
        stub.answer(nil)
        assert.is_false(got)
        stub.restore()
    end)

    it("defaults the title to Confirm", function()
        local stub = stub_select()
        Dialog.confirm({}, function() end)
        assert.equal("Confirm", stub.calls[1].opts.prompt)
        stub.restore()
    end)
end)
