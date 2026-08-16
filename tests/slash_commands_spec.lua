describe("local slash commands", function()
    local SlashCommands = require("agent-workbench.slash_commands")
    local CommandsCache = require("agent-workbench.cache.commands")

    after_each(function()
        CommandsCache.invalidate()
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
