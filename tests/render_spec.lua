-- Unit tests for pi.ui.render engine resolution (pure config logic, no plugin).

local Config = require("pi.config")
local Render = require("pi.ui.render")

describe("render engine resolution", function()
    after_each(function()
        -- restore the default so tests don't leak state
        Config.options.render = { engine = "builtin" }
        Render._reset()
    end)

    it("defaults to builtin", function()
        Config.options.render = nil
        assert.are.equal("builtin", Render.engine())
    end)

    it("reads an explicit engine", function()
        Config.options.render = { engine = "render-markdown" }
        assert.are.equal("render-markdown", Render.engine())
    end)

    it("treats a missing engine key as builtin", function()
        Config.options.render = {}
        assert.are.equal("builtin", Render.engine())
    end)
end)
