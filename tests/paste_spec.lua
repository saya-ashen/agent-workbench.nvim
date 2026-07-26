-- Unit tests for pi.paste (clipboard image paste interception). Hermetic:
-- img-clip and Pi.paste_image are stubbed, no real clipboard or session.

local Ft = require "pi.filetypes"

--- Install a fake `img-clip.clipboard` module.
---@param opts {clip_cmd?: string, is_image?: boolean}|nil  nil => module absent
local function stub_img_clip(opts)
  package.loaded["img-clip.clipboard"] = nil
  package.preload["img-clip.clipboard"] = nil
  if opts then
    package.preload["img-clip.clipboard"] = function()
      return {
        get_clip_cmd = function()
          return opts.clip_cmd
        end,
        content_is_image = function()
          return opts.is_image == true
        end,
      }
    end
  end
end

describe("pi.paste", function()
  local Paste = require "pi.paste"
  local Config = require "pi.config"
  local Pi = require "pi"

  local buf
  local orig_paste_image
  local orig_paste_image_cfg
  local attach_calls

  before_each(function()
    Paste._reset()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    attach_calls = 0
    orig_paste_image = Pi.paste_image
    Pi.paste_image = function()
      attach_calls = attach_calls + 1
      return true
    end
    orig_paste_image_cfg = Config.options.prompt.paste_image
    Config.options.prompt.paste_image = true
  end)

  after_each(function()
    Pi.paste_image = orig_paste_image
    Config.options.prompt.paste_image = orig_paste_image_cfg
    stub_img_clip(nil)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe("_clipboard_has_image", function()
    it("is false when img-clip is not installed", function()
      stub_img_clip(nil)
      assert.is_false(Paste._clipboard_has_image())
    end)

    it("is false when no clipboard tool is available", function()
      stub_img_clip { clip_cmd = nil, is_image = true }
      assert.is_false(Paste._clipboard_has_image())
    end)

    it("is false when the clipboard holds text", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = false }
      assert.is_false(Paste._clipboard_has_image())
    end)

    it("is true when the clipboard holds an image", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = true }
      assert.is_true(Paste._clipboard_has_image())
    end)
  end)

  describe("_make_handler", function()
    --- Run the handler, flushing any scheduled attach, and report what happened.
    ---@param filetype string
    ---@param phase integer
    ---@return boolean result, boolean orig_called
    local function run(filetype, phase)
      vim.bo[buf].filetype = filetype
      local orig_called = false
      local handler = Paste._make_handler(function(_, _)
        orig_called = true
        return true
      end)
      local result = handler({ "text" }, phase)
      vim.wait(20, function()
        return attach_calls > 0
      end)
      return result, orig_called
    end

    it("attaches and cancels the paste for an image in the prompt", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = true }
      local result, orig_called = run(Ft.prompt, -1)
      assert.is_false(result)
      assert.is_false(orig_called)
      assert.equals(1, attach_calls)
    end)

    it("delegates a normal text paste in the prompt", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = false }
      local result, orig_called = run(Ft.prompt, -1)
      assert.is_true(result)
      assert.is_true(orig_called)
      assert.equals(0, attach_calls)
    end)

    it("delegates when the target buffer is not the prompt", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = true }
      local result, orig_called = run("lua", -1)
      assert.is_true(result)
      assert.is_true(orig_called)
      assert.equals(0, attach_calls)
    end)

    it("delegates when paste_image is disabled", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = true }
      Config.options.prompt.paste_image = false
      local result, orig_called = run(Ft.prompt, -1)
      assert.is_true(result)
      assert.is_true(orig_called)
      assert.equals(0, attach_calls)
    end)

    it("delegates streamed paste phases", function()
      stub_img_clip { clip_cmd = "pngpaste", is_image = true }
      local result, orig_called = run(Ft.prompt, 1)
      assert.is_true(result)
      assert.is_true(orig_called)
      assert.equals(0, attach_calls)
    end)
  end)

  describe("setup", function()
    it("wraps vim.paste once", function()
      local before = vim.paste
      Paste.setup()
      local wrapped = vim.paste
      Paste.setup() -- idempotent
      assert.is_not.equal(before, wrapped)
      assert.equals(wrapped, vim.paste)
      vim.paste = before -- restore global handler for other specs
    end)
  end)
end)
