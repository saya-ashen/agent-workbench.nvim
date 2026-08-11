-- Unit tests for pi.json (depth-tolerant JSON decoder).
--
-- The decoder exists because vim.json (lua-cjson) hard-caps nesting at depth
-- 1000, which deep RPC payloads such as get_tree for a ~500+ message session
-- exceed. These specs pin: semantic parity with vim.json.decode on a corpus,
-- Node-style unicode escapes, arbitrary-depth parsing, strict rejection of
-- malformed input, and the vim.json special values (vim.NIL / vim.empty_dict).

local Json = require("pi.json")

--- vim.is_empty_dict does not exist in this nvim; empty dicts are recognized
--- by their metatable identity (vim.empty_dict() returns a fresh table with
--- the same shared metatable each call).
local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

---@param v any
---@return boolean
local function is_empty_dict(v)
    return type(v) == "table" and getmetatable(v) == EMPTY_DICT_MT
end

--- Deep equality across plain tables, vim.NIL, and vim.empty_dict() (which is
--- a fresh table per call, so == cannot be used).
---@param a any
---@param b any
---@return boolean
local function eq(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if is_empty_dict(a) or is_empty_dict(b) then
        return is_empty_dict(a) and is_empty_dict(b)
    end
    local ka, kb = {}, {}
    for k in pairs(a) do
        ka[#ka + 1] = k
    end
    for k in pairs(b) do
        kb[#kb + 1] = k
    end
    if #ka ~= #kb then
        return false
    end
    for _, k in ipairs(ka) do
        if not eq(a[k], b[k]) then
            return false
        end
    end
    return true
end

describe("pi.json", function()
    describe("parity with vim.json.decode", function()
        --- Encode an object with vim.json, decode with both decoders, compare.
        ---@param obj any
        ---@param desc string
        local function roundtrip(obj, desc)
            local json = vim.json.encode(obj)
            local expected = vim.json.decode(json)
            local actual, err = Json.decode(json)
            assert.is_nil(err, ("%s: %s"):format(desc, tostring(err)))
            assert.is_true(eq(expected, actual), desc .. " mismatch")
        end

        it("matches vim.json on a plain-values corpus", function()
            roundtrip({}, "empty object")
            roundtrip({ 1, 2, 3 }, "number array")
            roundtrip({ a = 1, b = "x", c = true, d = false }, "mixed object")
            roundtrip({ s = 'hello "quoted" \\ backslash / slash \n newline \t tab \r \b \f' }, "escapes")
            roundtrip({ u = "héllo 中文 🎉\0" }, "unicode + NUL")
            roundtrip({ nested = { deep = { deeper = { deepest = { x = 1 } } } } }, "nested tables")
            roundtrip({ arr = { { 1 }, { 2, { 3 } } }, n = -0.5, big = 1e21, neg = -1e-9 }, "numbers")
            roundtrip({ nullv = vim.NIL, empty_obj = vim.empty_dict(), empty_arr = {} }, "vim specials")
            roundtrip({ n = 9007199254740993 }, "int64 (lossy in both, identically)")
        end)

        it("matches vim.json on a session-shaped message", function()
            roundtrip({
                type = "tool_execution_end",
                toolName = "read",
                toolCallId = "call_1",
                args = { file_path = "lua/pi/json.lua" },
                result = {
                    content = { { type = "text", text = "line1\nline2" } },
                    details = { { path = "x", lines = { 1, 2, 3 } } },
                },
                success = true,
            }, "tool execution event")
        end)

        it("decodes Node-style unicode escapes including surrogate pairs", function()
            local json =
                '["\\u0000\\u0001\\u001f","\\ud83d\\ude00","\\ud83d\\udc68\\u200d\\ud83d\\udc69","\\u4f60\\u597d","plain"]'
            local expected = vim.json.decode(json)
            local actual, err = Json.decode(json)
            assert.is_nil(err)
            assert.is_true(eq(expected, actual), "unicode escape mismatch")
        end)

        it("matches vim.json on number spellings", function()
            for _, s in ipairs({ "0", "-0", "1", "-2.5", "1e3", "1E+3", "0.5e-2", "9007199254740993", "1e21" }) do
                local expected = vim.json.decode(s)
                local actual, err = Json.decode(s)
                assert.is_nil(err, ("%s: %s"):format(s, tostring(err)))
                assert.equals(expected, actual, s .. " mismatch")
            end
        end)
    end)

    describe("deep nesting (the get_tree failure mode)", function()
        --- Build a get_tree response JSON with a linear chain of n messages —
        --- exactly what pi emits: one {entry, children} level per message.
        ---@param n integer
        ---@return string
        local function tree_json(n)
            local sb = {}
            sb[#sb + 1] = '{"type":"response","command":"get_tree","success":true,"data":{"tree":['
            for i = 1, n do
                sb[#sb + 1] = '{"entry":{"type":"message","id":"m'
                    .. i
                    .. '","parentId":'
                    .. (i == 1 and "null" or ('"m' .. (i - 1) .. '"'))
                    .. ',"message":{"role":"user","content":"message number '
                    .. i
                    .. '"}},"children":['
            end
            sb[#sb + 1] = '{"entry":{"type":"message","id":"m'
                .. (n + 1)
                .. '","parentId":"m'
                .. n
                .. '","message":{"role":"assistant","content":"done"}},"children":[]}'
            for _ = 1, n do
                sb[#sb + 1] = "]}"
            end
            sb[#sb + 1] = '],"leafId":"m' .. (n + 1) .. '"}}'
            return table.concat(sb)
        end

        it("fails with vim.json (documents why the fallback exists)", function()
            assert.is_false(pcall(vim.json.decode, tree_json(1500)))
        end)

        it("decodes a tree well beyond cjson's 1000-level cap", function()
            local decoded, err = Json.decode(tree_json(1500))
            assert.is_nil(err)
            local node = decoded.data.tree[1]
            local depth = 0
            while node and node.children[1] do
                depth = depth + 1
                node = node.children[1]
            end
            assert.equals(1500, depth)
            assert.equals("m1501", decoded.data.leafId)
        end)

        it("rejects input deeper than its defensive cap", function()
            local json = string.rep("[", 8001) .. "1" .. string.rep("]", 8001)
            local decoded, err = Json.decode(json)
            assert.is_nil(decoded)
            assert.matches("nested", err)
        end)
    end)

    describe("strictness", function()
        it("rejects malformed input with an error message", function()
            local bad_inputs = {
                "",
                "   ",
                "{",
                "[1,",
                '{"a"}',
                '{"a":}',
                "[1 2]",
                "nul",
                "truex",
                "{'a':1}",
                "[1,2]x",
                -- leading zeros are invalid JSON (deliberately stricter than
                -- cjson, which accepts them — pi never emits them)
                "01",
                "[1e]",
                '"unterminated',
            }
            for _, bad in ipairs(bad_inputs) do
                local decoded, err = Json.decode(bad)
                assert.is_nil(decoded, ("accepted malformed %q"):format(bad))
                assert.is_not_nil(err, ("no error for %q"):format(bad))
            end
        end)

        it("rejects non-string input", function()
            local decoded, err = Json.decode(42)
            assert.is_nil(decoded)
            assert.matches("expected string", err)
        end)
    end)

    describe("top-level scalars and vim specials", function()
        it("decodes top-level scalars", function()
            assert.equals(42, Json.decode("42"))
            assert.equals("hi", Json.decode('"hi"'))
            assert.is_true(Json.decode("true"))
            assert.is_false(Json.decode("false"))
        end)

        it("maps null to vim.NIL", function()
            local v = Json.decode("null")
            assert.is_true(v == vim.NIL)
        end)

        it("maps {} to vim.empty_dict() and [] to a plain table", function()
            assert.is_true(is_empty_dict(Json.decode("{}")))
            local arr = Json.decode("[]")
            assert.is_not_nil(arr)
            assert.equals(0, #arr)
        end)
    end)
end)
