local Commands = require("agent-workbench.commands")

local LEGACY_PROBE = "PiNamespaceProbe"
local CANONICAL_PROBE = "AgentWorkbenchNamespaceProbe"

local function delete_probe_commands()
    pcall(vim.api.nvim_del_user_command, LEGACY_PROBE)
    pcall(vim.api.nvim_del_user_command, CANONICAL_PROBE)
end

describe("Agent Workbench namespace", function()
    after_each(function()
        delete_probe_commands()
        package.loaded["pi"] = nil
        package.loaded["pi.completion.blink"] = nil
        package.loaded["pi.health"] = nil
    end)

    it("loads the canonical API and deprecated root alias as the same module", function()
        local canonical = require("agent-workbench")
        local legacy = require("pi")

        assert.are.equal(canonical, legacy)
    end)

    it("keeps documented Blink and health compatibility modules", function()
        assert.are.equal(require("agent-workbench.completion.blink"), require("pi.completion.blink"))
        assert.are.equal(require("agent-workbench.health"), require("pi.health"))
    end)

    it("registers a canonical command without replacing an existing legacy command", function()
        local called = false
        vim.api.nvim_create_user_command(LEGACY_PROBE, function()
            called = true
        end, {})

        Commands._create_user_command(LEGACY_PROBE, function() end, {})

        assert.are.equal(2, vim.fn.exists(":" .. CANONICAL_PROBE))
        vim.cmd(LEGACY_PROBE)
        assert.is_true(called)
    end)
end)
