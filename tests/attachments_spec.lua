-- Unit tests for pi.ChatAttachments (attachment list buffer). Hermetic:
-- img-clip is stubbed for clipboard tests; file tests use real temp files.

local Config = require "pi.config"

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
  local Attachments = require "pi.ui.chat.attachments"

  local att
  local tmp_files

  before_each(function()
    att = Attachments.new()
    tmp_files = {}
  end)

  after_each(function()
    stub_img_clip(nil)
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
      stub_img_clip "YWJj" -- "abc" (3 bytes, no padding)
      assert.is_true(att:add_from_clipboard())
      assert.are_equal(3, att._items[1].size)
    end)

    it("accounts for base64 padding", function()
      stub_img_clip "YQ==" -- "a" (1 byte, 2 padding chars)
      assert.is_true(att:add_from_clipboard())
      assert.are_equal(1, att._items[1].size)
      stub_img_clip "YWI=" -- "ab" (2 bytes, 1 padding char)
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
end)
