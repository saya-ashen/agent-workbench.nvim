-- Unit tests for pi.draft (unsent-prompt persistence). Hermetic: uses a temp
-- file via the test path hook, never the real stdpath.

describe("pi.draft", function()
    local Draft = require("pi.draft")

    before_each(function()
        Draft._set_path(vim.fn.tempname() .. "/draft.txt")
        Draft._reset()
    end)

    after_each(function()
        Draft._set_path(nil)
        Draft._reset()
    end)

    describe("persistence", function()
        it("returns nil when there is no draft", function()
            assert.is_nil(Draft.load())
        end)

        it("round-trips save/load (multi-line)", function()
            Draft.save("line1\nline2")
            assert.are.equal("line1\nline2", Draft.load())
        end)

        it("save('') clears the stored draft", function()
            Draft.save("something")
            Draft.save("")
            assert.is_nil(Draft.load())
        end)

        it("clear removes the draft", function()
            Draft.save("x")
            Draft.clear()
            assert.is_nil(Draft.load())
        end)
    end)

    describe("restore_once", function()
        it("returns the draft on the first call only", function()
            Draft.save("my draft")
            assert.are.equal("my draft", Draft.restore_once())
            assert.is_nil(Draft.restore_once())
        end)

        it("leaves the file in place so an unsent draft survives", function()
            Draft.save("keep me")
            Draft.restore_once()
            assert.are.equal("keep me", Draft.load())
        end)

        it("returns nil when there is nothing to restore", function()
            assert.is_nil(Draft.restore_once())
        end)

        it("_reset allows restoring again (simulates a new process)", function()
            Draft.save("again")
            Draft.restore_once()
            Draft._reset()
            assert.are.equal("again", Draft.restore_once())
        end)
    end)
end)
