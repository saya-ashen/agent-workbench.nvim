local Registry = require("agent-workbench.backends")
local Workbench = require("agent-workbench")

local function factory(options)
    return { options = options }
end

describe("backend registry", function()
    before_each(function()
        Registry._reset()
    end)

    it("keeps pi as default and creates registered backends", function()
        assert.are.equal("pi", Registry.default())
        assert.is_true(Registry.has("pi"))

        Workbench.register_backend("contract-test", factory)
        local backend = assert(Registry.create("contract-test", { id = 7, cwd = "/tmp/workbench" }))
        assert.are.same({ id = 7, cwd = "/tmp/workbench" }, backend.options)
    end)

    it("passes backend options as opaque factory data", function()
        local marker = { nested = { value = true } }
        require("agent-workbench.config").setup({ backend_options = marker })
        assert.are.equal(marker, require("agent-workbench.config").options.backend_options)
    end)

    it("rejects invalid, duplicate, and unknown backends", function()
        assert.has_error(function()
            Registry.register("", factory)
        end)
        Registry.register("contract-test", factory)
        assert.has_error(function()
            Registry.register("contract-test", factory)
        end)
        local backend, err = Registry.create("missing", {})
        assert.is_nil(backend)
        assert.are.equal("Unknown backend: missing", err)
    end)
end)
