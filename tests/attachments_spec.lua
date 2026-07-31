-- Unit tests for pi.ChatAttachments (attachment list buffer). Hermetic:
-- img-clip is stubbed for clipboard tests; file tests use real temp files.

local Config = require("pi.config")

local Compress = require("pi.image_compress")

--- Install a fake `img-clip.clipboard` module returning `b64` as the image.
---@param b64 string|nil nil => module absent
local function stub_img_clip(b64)
    package.loaded["img-clip.clipboard"] = nil
    package.preload["img-clip.clipboard"] = nil
    if b64 then
        package.preload["img-clip.clipboard"] = function()
            return {
                get_clip_cmd = function()
                    return "fake-clip"
                end,
                content_is_image = function()
                    return true
                end,
                get_base64_encoded_image = function()
                    return b64
                end,
            }
        end
    end
end

--- Write `bytes` zero-bytes to a temp .png file and return its path.
---@param bytes integer
---@return string
local function make_image_file(bytes)
    local path = vim.fn.tempname() .. ".png"
    local f = assert(io.open(path, "wb"))
    f:write(string.rep("\0", bytes))
    f:close()
    return path
end

describe("pi.ChatAttachments", function()
    local Attachments = require("pi.ui.chat.attachments")

    local att
    local tmp_files
    local orig_compress
    local orig_executable
    local orig_system

    before_each(function()
        att = Attachments.new()
        tmp_files = {}
        -- Swap in a fresh image_compress copy with compression disabled so the
        -- plain add/remove tests stay synchronous and host-tool independent;
        -- restore the original table reference afterwards (no field leakage).
        orig_compress = Config.options.prompt.image_compress
        Config.options.prompt.image_compress = vim.tbl_deep_extend("force", {}, orig_compress, { enable = false })
        orig_executable = Compress._is_executable
        orig_system = vim.system
        Compress._reset()
    end)

    after_each(function()
        stub_img_clip(nil)
        Config.options.prompt.image_compress = orig_compress
        Compress._is_executable = orig_executable
        vim.system = orig_system
        Compress._reset()
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
        if vim.api.nvim_buf_is_valid(att:buf()) then
            vim.api.nvim_buf_delete(att:buf(), { force = true })
        end
    end)

    local function add_file(bytes)
        local path = make_image_file(bytes)
        tmp_files[#tmp_files + 1] = path
        assert.is_true(att:add_file(path))
        return path
    end

    local function buf_lines()
        return vim.api.nvim_buf_get_lines(att:buf(), 0, -1, false)
    end

    describe("size tracking", function()
        it("records the byte size for files", function()
            add_file(100)
            assert.are_equal(100, att._items[1].size)
        end)

        it("records the decoded byte size for clipboard images", function()
            stub_img_clip("YWJj") -- "abc" (3 bytes, no padding)
            assert.is_true(att:add_from_clipboard())
            assert.are_equal(3, att._items[1].size)
        end)

        it("accounts for base64 padding", function()
            stub_img_clip("YQ==") -- "a" (1 byte, 2 padding chars)
            assert.is_true(att:add_from_clipboard())
            assert.are_equal(1, att._items[1].size)
            stub_img_clip("YWI=") -- "ab" (2 bytes, 1 padding char)
            assert.is_true(att:add_from_clipboard())
            assert.are_equal(2, att._items[2].size)
        end)
    end)

    describe("rendering", function()
        it("shows the size suffix per item", function()
            add_file(100)
            add_file(2048)
            add_file(3 * 1024 * 1024)
            local icon = Config.options.labels.attachment
            local lines = buf_lines()
            assert.are_equal(icon .. " " .. vim.fn.fnamemodify(tmp_files[1], ":t") .. " (100 B)", lines[1])
            assert.are_same({ "(100 B)", "(2.0 KB)", "(3.0 MB)" }, {
                lines[1]:match("%b()$"),
                lines[2]:match("%b()$"),
                lines[3]:match("%b()$"),
            })
        end)

        it("highlights the size suffix with PiAttachmentSize", function()
            add_file(100)
            local marks = vim.api.nvim_buf_get_extmarks(att:buf(), -1, 0, -1, { details = true })
            local groups = {}
            for _, m in ipairs(marks) do
                groups[m[4].hl_group] = true
            end
            assert.is_true(groups["PiAttachmentIcon"] == true)
            assert.is_true(groups["PiAttachmentFilename"] == true)
            assert.is_true(groups["PiAttachmentSize"] == true)
        end)

        it("renders an empty line with no attachments", function()
            assert.are_same({ "" }, buf_lines())
        end)
    end)

    describe("add_file", function()
        it("rejects unsupported extensions", function()
            local path = vim.fn.tempname() .. ".txt"
            tmp_files[#tmp_files + 1] = path
            local f = assert(io.open(path, "wb"))
            f:write("x")
            f:close()
            assert.is_false(att:add_file(path))
            assert.are_equal(0, att:count())
        end)

        it("rejects unreadable files", function()
            assert.is_false(att:add_file("/nonexistent/definitely-not-there.png"))
            assert.are_equal(0, att:count())
        end)
    end)

    describe("remove/clear", function()
        it("remove re-renders the remaining items", function()
            add_file(100)
            add_file(200)
            att:remove(1)
            assert.are_equal(1, att:count())
            local lines = buf_lines()
            assert.are_equal("(200 B)", lines[1]:match("%b()$"))
        end)

        it("clear empties the buffer", function()
            add_file(100)
            att:clear()
            assert.are_equal(0, att:count())
            assert.are_same({ "" }, buf_lines())
        end)
    end)

    describe("compression integration", function()
        --- Stub the compressor to "convert" any input into a fresh `out_bytes`
        --- file at the output path (last argv element), reporting `code`.
        local function stub_system(out_bytes, code)
            vim.system = function(cmd, _opts, cb)
                local out = cmd[#cmd]
                local f = assert(io.open(out, "wb"))
                f:write(string.rep("\1", out_bytes))
                f:close()
                cb({ code = code, stderr = code == 0 and "" or "boom" })
            end
        end

        local function enable_compress(over)
            Config.options.prompt.image_compress = vim.tbl_deep_extend("force", {
                enable = true,
                max_dimension = 1568,
                quality = 80,
                format = "jpeg",
                tool = "auto",
                scope = "all",
            }, over or {})
            Compress._is_executable = function(tool)
                return tool == "sips"
            end
            Compress._reset()
        end

        local function wait_items(n)
            assert.is_true(vim.wait(500, function()
                return att:count() == n
            end))
        end

        it("compresses clipboard images and renames by output format", function()
            enable_compress()
            stub_system(10, 0)
            stub_img_clip(("QUJD"):rep(25)) -- 100 base64 chars → 75 bytes decoded
            assert.is_true(att:add_from_clipboard())
            wait_items(1)
            local item = att._items[1]
            assert.are_equal("cb-image-1.jpg", item.name)
            assert.are_equal("image/jpeg", item.mime)
            assert.are_equal(10, item.size)
            assert.are_equal("(10 B)", buf_lines()[1]:match("%b()$"))
        end)

        it("falls back to the original on compression failure", function()
            enable_compress()
            stub_system(0, 1)
            stub_img_clip("YWJj") -- "abc"
            assert.is_true(att:add_from_clipboard())
            wait_items(1)
            local item = att._items[1]
            assert.are_equal("cb-image-1.png", item.name)
            assert.are_equal("image/png", item.mime)
            assert.are_equal(3, item.size)
        end)

        it("compresses attached files when scope = all", function()
            enable_compress()
            stub_system(10, 0)
            local path = make_image_file(100)
            tmp_files[#tmp_files + 1] = path
            assert.is_true(att:add_file(path))
            wait_items(1)
            local item = att._items[1]
            assert.are_equal((vim.fn.fnamemodify(path, ":t:r")) .. ".jpg", item.name)
            assert.are_equal("image/jpeg", item.mime)
            assert.are_equal(10, item.size)
        end)

        it("attaches files synchronously when scope = clipboard", function()
            enable_compress({ scope = "clipboard" })
            stub_system(10, 0)
            local path = make_image_file(100)
            tmp_files[#tmp_files + 1] = path
            assert.is_true(att:add_file(path))
            assert.are_equal(1, att:count()) -- synchronous, no wait
            assert.are_equal(100, att._items[1].size)
        end)

        it("never touches svg even when compression is enabled", function()
            enable_compress()
            vim.system = function()
                error("vim.system must not run for svg")
            end
            local path = vim.fn.tempname() .. ".svg"
            tmp_files[#tmp_files + 1] = path
            local f = assert(io.open(path, "wb"))
            f:write(string.rep("x", 42))
            f:close()
            assert.is_true(att:add_file(path))
            assert.are_equal(1, att:count())
            assert.are_equal(42, att._items[1].size)
        end)
    end)
end)
