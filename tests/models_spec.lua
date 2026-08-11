-- Configured model entry resolution: `models` entries (strings and specs)
-- are resolved against the backend model list for cycling and the picker.

local Config = require("pi.config")

Config.setup({})

--- vim.notify spy records.
local notes = {}

vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
end

---@type table[]
local all_models = {
    { provider = "kimi-coding", id = "k3", name = "Kimi K3" },
    { provider = "opencode-go", id = "kimi-k3", name = "Kimi K3" },
    { provider = "opencode-go", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "deepseek", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "qwen-token-plan-cn", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "kimi-coding", id = "kimi-for-coding", name = "Kimi for Coding" },
}

describe("models.resolve_entries", function()
    before_each(function()
        notes = {}
    end)

    it("matches a string entry by exact ID", function()
        local resolved = require("pi.models").resolve_entries({ "k3" }, all_models)
        assert.are.same(1, #resolved)
        assert.are.same("kimi-coding", resolved[1].provider)
        assert.are.same("k3", resolved[1].id)
    end)

    it("matches a string entry by canonical provider/modelId", function()
        local resolved = require("pi.models").resolve_entries({ "opencode-go/deepseek-v4-flash" }, all_models)
        assert.are.same(1, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
        assert.are.same("deepseek-v4-flash", resolved[1].id)
    end)

    it("matches every provider copy of a bare ambiguous ID", function()
        local resolved = require("pi.models").resolve_entries({ "deepseek-v4-flash" }, all_models)
        assert.are.same(3, #resolved)
    end)

    it("dedupes across providers only within the same entry form", function()
        -- Canonical entry pins the opencode-go copy; the bare entry still
        -- matches the other providers' copies.
        local resolved =
            require("pi.models").resolve_entries({ "opencode-go/deepseek-v4-flash", "deepseek-v4-flash" }, all_models)
        assert.are.same(3, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
    end)

    it("matches an exact spec by canonical provider/modelId", function()
        local resolved = require("pi.models").resolve_entries(
            { { match = "opencode-go/deepseek-v4-flash", exact = true } },
            all_models
        )
        assert.are.same(1, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
    end)

    it("warns when a string entry matches nothing", function()
        local resolved = require("pi.models").resolve_entries({ "no-such-model" }, all_models)
        assert.are.same(0, #resolved)
        assert.are.same(1, #notes)
        assert.matches("Configured model not found", notes[1].msg)
    end)
end)
