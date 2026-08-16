--- Depth-tolerant JSON decoder for incoming RPC payloads.
---
--- Neovim's `vim.json.decode` (bundled lua-cjson) hard-caps JSON nesting at
--- depth 1000 — a compile-time constant shared by every cjson instance,
--- including `vim.json.new()`. Deep payloads such as the `get_tree` response
--- for a session with ~500+ messages (the tree nests one `children` level per
--- message) exceed that limit and cjson aborts mid-parse, dropping the whole
--- message. This module decodes the same JSON without a depth limit (defensive
--- cap 20000).
---
--- Semantics mirror `vim.json.decode` so consumers cannot tell the decoders
--- apart: `null` -> `vim.NIL`, `{}` -> `vim.empty_dict()`, `[]` -> plain table,
--- `\uXXXX` escapes -> UTF-8 (surrogate pairs combined; unpaired surrogates are
--- encoded as-is, which is more lenient than cjson), numbers via `tonumber`
--- (same int64-lossy behavior as cjson). Strict JSON: malformed input returns
--- `nil, error message`.

local M = {}

--- Maximum nesting depth before the decoder gives up. Never hit by real pi
--- payloads (a session would need ~4000+ messages); guards against LuaJIT
--- stack overflow on hostile input — recursion dies somewhere above ~12000
--- levels, so 8000 leaves a wide margin.
local MAX_DEPTH = 8000

---@param str string
---@return any value decoded value (table, string, number, boolean, or vim.NIL)
---@return string? error message when the input is not valid JSON
function M.decode(str)
    if type(str) ~= "string" then
        return nil, "json.decode: expected string, got " .. type(str)
    end
    local len = #str
    local pos = 1

    local function fail(msg)
        return nil, string.format("json.decode: %s at character %d", msg, pos)
    end

    local function skip_ws()
        -- Fast path: pi emits compact JSON without whitespace, so just check
        -- one byte instead of running a pattern find on every token.
        local b = str:byte(pos)
        if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then -- not space/tab/nl/cr
            return
        end
        local s, e = str:find("%S", pos)
        pos = e or (len + 1)
    end

    --- Parse a string literal; the current byte (after skip_ws) must be `"`.
    ---@return string? value
    ---@return string? error
    local function parse_string()
        local start = pos + 1
        local q = str:find('"', start, true)
        if not q then
            return fail("unterminated string")
        end
        -- Fast path: no backslash between the opening and closing quotes.
        local bs = str:find("\\", start, true)
        if not bs or bs > q then
            pos = q + 1
            return str:sub(start, q - 1)
        end
        -- Slow path: unescape each escape sequence.
        local out = {}
        local i = start
        while true do
            if bs > i then
                out[#out + 1] = str:sub(i, bs - 1)
            end
            local esc = bs + 1
            local advance = 2 -- chars consumed: backslash + the escaped char
            if esc > len then
                return fail("unterminated string escape")
            end
            local c = str:byte(esc)
            if c == 34 then -- "
                out[#out + 1] = '"'
            elseif c == 92 then -- \
                out[#out + 1] = "\\"
            elseif c == 47 then -- /
                out[#out + 1] = "/"
            elseif c == 98 then -- b
                out[#out + 1] = "\b"
            elseif c == 102 then -- f
                out[#out + 1] = "\f"
            elseif c == 110 then -- n
                out[#out + 1] = "\n"
            elseif c == 114 then -- r
                out[#out + 1] = "\r"
            elseif c == 116 then -- t
                out[#out + 1] = "\t"
            elseif c == 117 then -- u
                advance = 6
                local h = str:sub(esc + 1, esc + 4)
                if not h:match("^%x%x%x%x$") then
                    return fail("invalid \\u escape")
                end
                local cp = tonumber(h, 16)
                if cp >= 0xd800 and cp <= 0xdbff then
                    -- High surrogate: combine with a following low surrogate
                    -- escape when present; otherwise encode as-is (cjson
                    -- rejects unpaired surrogates, we deliver them).
                    if str:sub(esc + 5, esc + 6) == "\\u" and str:sub(esc + 7, esc + 10):match("^%x%x%x%x$") then
                        local lo = tonumber(str:sub(esc + 7, esc + 10), 16)
                        if lo >= 0xdc00 and lo <= 0xdfff then
                            cp = 0x10000 + (cp - 0xd800) * 0x400 + (lo - 0xdc00)
                            advance = 12
                        end
                    end
                end
                -- UTF-8 encode
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xc0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
                elseif cp < 0x10000 then
                    out[#out + 1] = string.char(
                        0xe0 + math.floor(cp / 0x1000),
                        0x80 + math.floor(cp / 0x40) % 0x40,
                        0x80 + cp % 0x40
                    )
                else
                    out[#out + 1] = string.char(
                        0xf0 + math.floor(cp / 0x40000),
                        0x80 + math.floor(cp / 0x1000) % 0x40,
                        0x80 + math.floor(cp / 0x40) % 0x40,
                        0x80 + cp % 0x40
                    )
                end
            else
                return fail("invalid escape \\" .. string.char(c))
            end
            i = bs + advance
            q = str:find('"', i, true)
            if not q then
                return fail("unterminated string")
            end
            bs = str:find("\\", i, true)
            if not bs or bs > q then
                out[#out + 1] = str:sub(i, q - 1)
                pos = q + 1
                return table.concat(out)
            end
        end
    end

    ---@return number?
    local function parse_number()
        -- JSON numbers: optional minus, optional fraction and exponent. Leading
        -- zeros are rejected afterwards (stricter than cjson, which accepts
        -- "01" — pi never emits them).
        local n = str:match("^%-?%d+%.?%d*[eE][%+%-]?%d+", pos) or str:match("^%-?%d+%.?%d*", pos)
        if not n or n:match("^%-?0%d") then
            return nil
        end
        pos = pos + #n
        return tonumber(n)
    end

    ---@param depth integer
    ---@return any? value
    ---@return string? error
    local function parse_value(depth)
        skip_ws()
        if pos > len then
            return fail("unexpected end of input")
        end
        if depth > MAX_DEPTH then
            return fail("too deeply nested")
        end
        local b = str:byte(pos)
        if b == 123 then -- {
            pos = pos + 1
            local t = {}
            skip_ws()
            if str:byte(pos) == 125 then -- }
                pos = pos + 1
                return vim.empty_dict()
            end
            while true do
                skip_ws()
                if str:byte(pos) ~= 34 then -- "
                    return fail("expected string key")
                end
                local key, kerr = parse_string()
                if key == nil then
                    return nil, kerr
                end
                skip_ws()
                if str:byte(pos) ~= 58 then -- :
                    return fail("expected ':'")
                end
                pos = pos + 1
                local v, verr = parse_value(depth + 1)
                if v == nil then
                    return nil, verr
                end
                t[key] = v
                skip_ws()
                local c = str:byte(pos)
                if c == 44 then -- ,
                    pos = pos + 1
                elseif c == 125 then -- }
                    pos = pos + 1
                    if next(t) == nil then
                        return vim.empty_dict()
                    end
                    return t
                else
                    return fail("expected ',' or '}'")
                end
            end
        elseif b == 91 then -- [
            pos = pos + 1
            local t = {}
            skip_ws()
            if str:byte(pos) == 93 then -- ]
                pos = pos + 1
                return t
            end
            while true do
                local v, verr = parse_value(depth + 1)
                if v == nil then
                    return nil, verr
                end
                t[#t + 1] = v
                skip_ws()
                local c = str:byte(pos)
                if c == 44 then -- ,
                    pos = pos + 1
                elseif c == 93 then -- ]
                    pos = pos + 1
                    return t
                else
                    return fail("expected ',' or ']'")
                end
            end
        elseif b == 34 then -- "
            return parse_string()
        elseif b == 116 then -- t
            if str:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                return true
            end
            return fail("invalid literal")
        elseif b == 102 then -- f
            if str:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                return false
            end
            return fail("invalid literal")
        elseif b == 110 then -- n
            if str:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                return vim.NIL
            end
            return fail("invalid literal")
        elseif b == 45 or (b >= 48 and b <= 57) then -- - or digit
            local n = parse_number()
            if n == nil then
                return fail("invalid number")
            end
            return n
        end
        return fail("invalid value")
    end

    local v, verr = parse_value(0)
    if v == nil then
        return nil, verr
    end
    skip_ws()
    if pos <= len then
        return fail("trailing characters")
    end
    return v
end

return M
