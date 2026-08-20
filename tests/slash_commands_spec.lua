describe("local slash commands", function()
    local SlashCommands = require("agent-workbench.slash_commands")
    local CommandsCache = require("agent-workbench.cache.commands")

    after_each(function()
        CommandsCache.invalidate()
        SlashCommands._reset_argument_cache()
    end)

    it("merges local and backend commands without duplicates", function()
        CommandsCache.set({
            { name = "new", description = "backend duplicate", source = "extension" },
            { name = "review", description = "Review changes", source = "extension" },
        })
        local names = {}
        for _, command in ipairs(SlashCommands.list()) do
            names[command.name] = (names[command.name] or 0) + 1
        end
        assert.are.equal(1, names.new)
        assert.are.equal(1, names.review)
        assert.is_truthy(names.replace)
        assert.is_truthy(names.resume)
        assert.is_truthy(names.model)
        assert.is_truthy(names.thinking)
        assert.is_truthy(names.compact)
        assert.is_truthy(names.name)
        assert.is_truthy(names.session)
        assert.is_truthy(names.abort)
    end)

    it("matches skill commands by short name before fuzzy matches", function()
        CommandsCache.set({
            { name = "skill:review", description = "Review skill", source = "skill" },
            { name = "remove-view", description = "Fuzzy match", source = "extension" },
        })
        local matches = SlashCommands.match("rev")
        assert.are.equal("skill:review", matches[1].name)
    end)

    it("completes /model arguments from one cached RPC request", function()
        local context = assert(SlashCommands.argument_context("/model ", 7))
        assert.are.same({ name = "model", prefix = "", start = 7 }, context)
        assert.is_nil(SlashCommands.argument_context("/name ", 6))

        local old_manager = package.loaded["agent-workbench.sessions.manager"]
        local response
        local sends = 0
        local session = {
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_, msg, callback)
                    sends = sends + 1
                    assert.are.equal("get_available_models", msg.type)
                    response = callback
                    return true
                end,
            },
        }
        package.loaded["agent-workbench.sessions.manager"] = {
            get = function()
                return session
            end,
        }

        local ok, err = pcall(function()
            local all
            local filtered
            SlashCommands.request_argument_completions("model", "", function(items)
                all = items
            end)
            SlashCommands.request_argument_completions("model", "gpt", function(items)
                filtered = items
            end)
            assert.are.equal(1, sends)
            assert.is_nil(all)
            assert.is_nil(filtered)

            assert(response)({
                success = true,
                data = {
                    models = {
                        { provider = "anthropic", id = "claude-sonnet", name = "Claude Sonnet" },
                        { provider = "openai", id = "gpt-5.3-codex", name = "GPT Codex" },
                    },
                },
            })
            vim.wait(100, function()
                return all ~= nil and filtered ~= nil
            end)

            assert.are.equal(2, #all)
            assert.are.same({
                value = "openai/gpt-5.3-codex",
                label = "gpt-5.3-codex",
                description = "openai",
            }, filtered[1])
            SlashCommands.request_argument_completions("model", "claude", function() end)
            assert.are.equal(1, sends)

            local buf = vim.api.nvim_get_current_buf()
            local original = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "/model gpt" })
            vim.api.nvim_win_set_cursor(0, { 1, #"/model gpt" })
            local Omnifunc = require("agent-workbench.completion.omnifunc")
            assert.are.equal(7, Omnifunc.completefunc(1, ""))
            local omni_items = Omnifunc.completefunc(0, "gpt")
            assert.are.equal("openai/gpt-5.3-codex", omni_items[1].word)
            assert.are.equal("gpt-5.3-codex", omni_items[1].abbr)
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { original })
            vim.api.nvim_win_set_cursor(0, { 1, 0 })

            local blink_result
            require("agent-workbench.completion.blink")
                .new()
                :get_completions({ line = "/model gpt", cursor = { 1, #"/model gpt" } }, function(result)
                    blink_result = result
                end)
            assert.are.equal("openai/gpt-5.3-codex", blink_result.items[1].insertText)
            assert.are.equal("gpt-5.3-codex", blink_result.items[1].label)
        end)
        package.loaded["agent-workbench.sessions.manager"] = old_manager
        assert.is_true(ok, err)
    end)

    it("completes /thinking arguments supported by the current model", function()
        local context = assert(SlashCommands.argument_context("/thinking ", 10))
        assert.are.same({ name = "thinking", prefix = "", start = 10 }, context)
        context = assert(SlashCommands.argument_context("/thinking hi", 12))
        assert.are.same({ name = "thinking", prefix = "hi", start = 10 }, context)

        local old_manager = package.loaded["agent-workbench.sessions.manager"]
        local responses = {}
        local sends = 0
        local session = {
            pinned_model = { provider = "openai", id = "gpt-5.3-codex" },
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_, msg, callback)
                    sends = sends + 1
                    assert.are.equal("get_available_thinking_levels", msg.type)
                    responses[sends] = callback
                    return true
                end,
            },
        }
        package.loaded["agent-workbench.sessions.manager"] = {
            get = function()
                return session
            end,
        }

        local ok, err = pcall(function()
            local all
            local filtered
            SlashCommands.request_argument_completions("thinking", "", function(items)
                all = items
            end)
            SlashCommands.request_argument_completions("thinking", "hi", function(items)
                filtered = items
            end)
            assert.are.equal(1, sends)
            assert.is_nil(all)
            assert.is_nil(filtered)

            assert(responses[1])({
                success = true,
                data = { levels = { "off", "minimal", "low", "medium", "high", "xhigh", "max" } },
            })
            vim.wait(100, function()
                return all ~= nil and filtered ~= nil
            end)

            assert.are.equal(7, #all)
            assert.are.same({ value = "high", label = "high", description = "thinking level" }, filtered[1])
            local xhigh
            SlashCommands.request_argument_completions("thinking", "xh", function(items)
                xhigh = items
            end)
            assert.are.equal(1, sends)
            assert.are.equal("xhigh", xhigh[1].value)

            local buf = vim.api.nvim_get_current_buf()
            local original = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "/thinking hi" })
            vim.api.nvim_win_set_cursor(0, { 1, #"/thinking hi" })
            local Omnifunc = require("agent-workbench.completion.omnifunc")
            assert.are.equal(10, Omnifunc.completefunc(1, ""))
            local omni_items = Omnifunc.completefunc(0, "hi")
            assert.are.equal("high", omni_items[1].word)
            assert.are.equal("high", omni_items[1].abbr)
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { original })
            vim.api.nvim_win_set_cursor(0, { 1, 0 })

            local blink_result
            require("agent-workbench.completion.blink")
                .new()
                :get_completions({ line = "/thinking hi", cursor = { 1, #"/thinking hi" } }, function(result)
                    blink_result = result
                end)
            assert.are.equal("high", blink_result.items[1].insertText)
            assert.are.equal("high", blink_result.items[1].label)

            session.pinned_model = { provider = "anthropic", id = "claude-sonnet" }
            local switched
            SlashCommands.request_argument_completions("thinking", "", function(items)
                switched = items
            end)
            assert.are.equal(2, sends)
            assert.is_nil(switched)
            assert(responses[2])({ success = true, data = { levels = { "off" } } })
            vim.wait(100, function()
                return switched ~= nil
            end)
            assert.are.equal(1, #switched)
            assert.are.equal("off", switched[1].value)
        end)
        package.loaded["agent-workbench.sessions.manager"] = old_manager
        assert.is_true(ok, err)
    end)

    it("dispatches picker and lifecycle commands locally", function()
        local called = {}
        local old_pi = package.loaded["agent-workbench"]
        package.loaded["agent-workbench"] = {
            new_session = function()
                called.new = true
            end,
            replace_session = function()
                called.replace = true
            end,
            resume_session = function()
                called.resume = true
            end,
            select_model = function()
                called.model = true
            end,
            select_thinking_level = function()
                called.thinking = true
            end,
            compact = function(value)
                called.compact = value or true
            end,
            set_session_name = function(value)
                called.name = value or true
            end,
            sessions = function()
                called.session = true
            end,
            abort = function()
                called.abort = true
            end,
        }

        local ok, err = pcall(function()
            assert.is_true(SlashCommands.execute("/new ignored"))
            assert.is_true(SlashCommands.execute("/replace ignored"))
            assert.is_true(SlashCommands.execute("/resume ignored"))
            assert.is_true(SlashCommands.execute("/model"))
            assert.is_true(SlashCommands.execute("/thinking"))
            assert.is_true(SlashCommands.execute("/compact keep decisions"))
            assert.is_true(SlashCommands.execute("/name focused work"))
            assert.is_true(SlashCommands.execute("/session ignored"))
            assert.is_true(SlashCommands.execute("/abort ignored"))
            assert.is_false(SlashCommands.execute("/extension-command"))
        end)
        package.loaded["agent-workbench"] = old_pi
        assert.is_true(ok, err)

        assert.is_true(called.new)
        assert.is_true(called.replace)
        assert.is_true(called.resume)
        assert.is_true(called.model)
        assert.is_true(called.thinking)
        assert.are.equal("keep decisions", called.compact)
        assert.are.equal("focused work", called.name)
        assert.is_true(called.session)
        assert.is_true(called.abort)
    end)
end)
