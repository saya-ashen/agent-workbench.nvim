-- Regression: RPC stdout reassembly must stay O(n) for large single-line responses.
--
-- A `get_messages` response for a big session is one multi-MB JSON line. The old
-- _on_stdout grew the pending partial line via repeated string concatenation
-- (`self._stdout_buf .. data[1]`) on every incoming chunk, which is O(n^2) and
-- took seconds to load a large session. The fix buffers chunks in a table and
-- concatenates once when the line completes. These specs pin the reassembly
-- semantics (partial lines across chunks, multiple lines per chunk, empty
-- keepalive chunks) plus a large-line performance guard.

local Config = require("pi.config")
local Rpc = require("pi.rpc")

Config.setup({})

--- Build an Rpc whose dispatched messages are recorded into `out`.
local function make_rpc(out)
    local rpc = Rpc.new("test")
    rpc:set_handler(function(msg)
        out[#out + 1] = msg
    end)
    return rpc
end

local function jsonl(t)
    return vim.json.encode(t)
end

describe("rpc stdout reassembly", function()
    it("decodes a complete line delivered in one chunk", function()
        local out = {}
        local rpc = make_rpc(out)
        rpc:_on_stdout({ jsonl({ type = "response", id = "1" }), "" })
        assert.equals(1, #out)
        assert.equals("1", out[1].id)
    end)

    it("reassembles a line split across multiple chunks", function()
        local out = {}
        local rpc = make_rpc(out)
        local line = jsonl({ type = "response", id = "split", payload = string.rep("a", 100) })
        local third = math.floor(#line / 3)
        rpc:_on_stdout({ line:sub(1, third) }) -- no newline yet
        rpc:_on_stdout({ line:sub(third + 1, 2 * third) }) -- still no newline
        rpc:_on_stdout({ line:sub(2 * third + 1), "" }) -- final piece + newline
        assert.equals(1, #out)
        assert.equals("split", out[1].id)
        assert.equals(string.rep("a", 100), out[1].payload)
    end)

    it("decodes several complete lines arriving in one chunk", function()
        local out = {}
        local rpc = make_rpc(out)
        rpc:_on_stdout({ jsonl({ type = "a" }), jsonl({ type = "b" }), "" })
        assert.equals(2, #out)
        assert.equals("a", out[1].type)
        assert.equals("b", out[2].type)
    end)

    it("handles a trailing partial line followed by more data", function()
        local out = {}
        local rpc = make_rpc(out)
        local l1 = jsonl({ type = "first" })
        local l2 = jsonl({ type = "second" })
        -- chunk ends mid-line: l1 complete, l2 partial
        rpc:_on_stdout({ l1, l2:sub(1, 5) })
        assert.equals(1, #out)
        -- next chunk finishes l2
        rpc:_on_stdout({ l2:sub(6), "" })
        assert.equals(2, #out)
        assert.equals("second", out[2].type)
    end)

    it("ignores empty keepalive chunks without corrupting the next line", function()
        local out = {}
        local rpc = make_rpc(out)
        rpc:_on_stdout({ "" })
        rpc:_on_stdout({ "" })
        rpc:_on_stdout({ jsonl({ type = "after" }), "" })
        assert.equals(1, #out)
        assert.equals("after", out[1].type)
    end)

    it("reassembles a large single-line response in linear time (perf guard)", function()
        local out = {}
        local rpc = make_rpc(out)
        local line = jsonl({ type = "response", id = "big", blob = string.rep("z", 20 * 1024 * 1024) })
        -- Deliver in 64KB chunks like a real job stdout, no newline until the end.
        local chunk = 64 * 1024
        local t0 = vim.uv.hrtime()
        local i = 1
        while i <= #line do
            local piece = line:sub(i, i + chunk - 1)
            if i + chunk - 1 >= #line then
                rpc:_on_stdout({ piece, "" })
            else
                rpc:_on_stdout({ piece })
            end
            i = i + chunk
        end
        local ms = (vim.uv.hrtime() - t0) / 1e6
        assert.equals(1, #out)
        assert.equals("big", out[1].id)
        -- The O(n^2) version took ~3s for 20MB at 64KB chunks; linear is well under.
        assert.is_true(ms < 800, string.format("large-line reassembly took %.1f ms (O(n^2) regression?)", ms))
    end)
end)
