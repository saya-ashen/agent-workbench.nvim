-- Unit tests for pi.image_compress (external-tool image compression).
-- Hermetic: executable probing and vim.system are stubbed; no real tools run.

local Compress = require "pi.image_compress"
local Config = require "pi.config"

---@param over table<string, any>|nil
---@return pi.ImageCompressConfig
local function cfg(over)
  return vim.tbl_deep_extend("force", {
    enable = true,
    max_dimension = 1568,
    quality = 80,
    format = "keep",
    tool = "auto",
    scope = "all",
  }, over or {})
end

--- Write `bytes` zero-bytes to a temp file and return its path.
---@param bytes integer
---@param ext string
---@return string
local function make_file(bytes, ext)
  local path = vim.fn.tempname() .. ext
  local f = assert(io.open(path, "wb"))
  f:write(string.rep("\0", bytes))
  f:close()
  return path
end

describe("pi.image_compress", function()
  local tmp_files
  local orig_executable
  local orig_system

  before_each(function()
    tmp_files = {}
    Compress._reset()
    orig_executable = Compress._is_executable
    orig_system = vim.system
  end)

  after_each(function()
    Compress._is_executable = orig_executable
    vim.system = orig_system
    Compress._reset()
    for _, path in ipairs(tmp_files) do
      os.remove(path)
    end
  end)

  ---@param tools table<string, boolean>
  local function stub_executables(tools)
    Compress._is_executable = function(tool)
      return tools[tool] == true
    end
  end

  describe("tool detection", function()
    it("prefers sips, then magick, then ffmpeg", function()
      stub_executables { sips = true, magick = true, ffmpeg = true }
      assert.are_equal("sips", Compress._detect_tool "auto")
      Compress._reset()
      stub_executables { magick = true, ffmpeg = true }
      assert.are_equal("magick", Compress._detect_tool "auto")
      Compress._reset()
      stub_executables { ffmpeg = true }
      assert.are_equal("ffmpeg", Compress._detect_tool "auto")
    end)

    it("returns nil when nothing is available", function()
      stub_executables {}
      assert.is_nil(Compress._detect_tool "auto")
    end)

    it("caches the auto probe", function()
      local calls = 0
      Compress._is_executable = function()
        calls = calls + 1
        return true
      end
      assert.are_equal("sips", Compress._detect_tool "auto")
      assert.are_equal("sips", Compress._detect_tool "auto")
      assert.are_equal(1, calls)
    end)

    it("honors an explicit tool but checks executability", function()
      stub_executables { sips = true }
      assert.are_equal("sips", Compress._detect_tool "sips")
      assert.is_nil(Compress._detect_tool "magick")
    end)
  end)

  describe("supported", function()
    it("accepts png/jpeg/webp and rejects svg/gif", function()
      assert.is_true(Compress.supported "image/png")
      assert.is_true(Compress.supported "image/jpeg")
      assert.is_true(Compress.supported "image/webp")
      assert.is_false(Compress.supported "image/svg+xml")
      assert.is_false(Compress.supported "image/gif")
    end)
  end)

  describe("format resolution", function()
    it("keep maps to the input format", function()
      assert.are_equal("png", Compress._resolve_format(cfg(), "sips", "image/png"))
      assert.are_equal("jpeg", Compress._resolve_format(cfg(), "magick", "image/jpeg"))
    end)

    it("webp degrades to keep under sips", function()
      assert.are_equal("png", Compress._resolve_format(cfg { format = "webp" }, "sips", "image/png"))
      assert.are_equal("webp", Compress._resolve_format(cfg { format = "webp" }, "magick", "image/png"))
    end)

    it("invalid values fall back to keep", function()
      assert.are_equal("png", Compress._resolve_format(cfg { format = "bogus" }, "sips", "image/png"))
    end)

    it("png output without resize is a no-op", function()
      assert.is_true(Compress._is_noop(cfg { max_dimension = 0 }, "png"))
      assert.is_false(Compress._is_noop(cfg { max_dimension = 0 }, "jpeg"))
      assert.is_false(Compress._is_noop(cfg { max_dimension = 1568 }, "png"))
    end)
  end)

  describe("command construction", function()
    local opts = { max_dimension = 1568, quality = 80, format = "jpeg" }

    it("sips: resize, format, quality, positional input, --out", function()
      assert.are_same(
        { "sips", "-Z", "1568", "-s", "format", "jpeg", "-s", "formatOptions", "80", "in.png", "--out", "out.jpg" },
        Compress._build_cmd("sips", "in.png", "out.jpg", opts)
      )
    end)

    it("sips: png output omits formatOptions; max_dimension=0 omits -Z", function()
      assert.are_same(
        { "sips", "-s", "format", "png", "in.png", "--out", "out.png" },
        Compress._build_cmd("sips", "in.png", "out.png", { max_dimension = 0, quality = 80, format = "png" })
      )
    end)

    it("magick: shrink-only resize and quality", function()
      assert.are_same(
        { "magick", "in.png", "-resize", "1568x1568>", "-quality", "80", "out.jpg" },
        Compress._build_cmd("magick", "in.png", "out.jpg", opts)
      )
    end)

    it("magick: png output omits -quality", function()
      assert.are_same(
        { "magick", "in.png", "-resize", "1568x1568>", "out.png" },
        Compress._build_cmd("magick", "in.png", "out.png", { max_dimension = 1568, quality = 80, format = "png" })
      )
    end)

    it("ffmpeg: aspect-preserving scale and mapped qscale", function()
      assert.are_same(
        {
          "ffmpeg", "-y", "-i", "in.png",
          "-vf", "scale=w=1568:h=1568:force_original_aspect_ratio=decrease",
          "-q:v", "8", -- quality 80 → 2 + 29*0.2
          "out.jpg",
        },
        Compress._build_cmd("ffmpeg", "in.png", "out.jpg", opts)
      )
    end)

    it("ffmpeg: webp uses -quality", function()
      local cmd = Compress._build_cmd("ffmpeg", "in.png", "out.webp", { max_dimension = 0, quality = 80, format = "webp" })
      assert.are_same({ "ffmpeg", "-y", "-i", "in.png", "-quality", "80", "out.webp" }, cmd)
    end)
  end)

  describe("compress_async", function()
    --- Stub vim.system: writes `out_bytes` to the output path (last argv
    --- element) and calls back with `code`.
    local function stub_system(out_bytes, code)
      vim.system = function(cmd, _opts, cb)
        local out = cmd[#cmd]
        local f = assert(io.open(out, "wb"))
        f:write(string.rep("\0", out_bytes))
        f:close()
        cb({ code = code, stderr = code == 0 and "" or "boom" })
      end
    end

    --- Run compress_async and return the callback args (waiting out the
    --- schedule_wrap when the tool path runs async).
    local function run(input, mime, c)
      local result
      Compress.compress_async(input, mime, c, function(path, out_mime, err)
        result = { path = path, mime = out_mime, err = err }
      end)
      vim.wait(200, function()
        return result ~= nil
      end)
      assert.is_not_nil(result)
      return result
    end

    it("skips silently when disabled", function()
      stub_executables { sips = true }
      local res = run("in.png", "image/png", cfg { enable = false })
      assert.is_nil(res.path)
      assert.is_nil(res.err)
    end)

    it("skips silently for unsupported mime", function()
      stub_executables { sips = true }
      local res = run("in.svg", "image/svg+xml", cfg())
      assert.is_nil(res.path)
    end)

    it("skips silently when no tool is available", function()
      stub_executables {}
      local res = run("in.png", "image/png", cfg())
      assert.is_nil(res.path)
    end)

    it("skips silently on the png no-op", function()
      stub_executables { sips = true }
      local res = run("in.png", "image/png", cfg { max_dimension = 0 })
      assert.is_nil(res.path)
    end)

    it("returns the output path and mime on success", function()
      stub_executables { sips = true }
      stub_system(10, 0)
      local input = make_file(100, ".png")
      tmp_files[#tmp_files + 1] = input
      local res = run(input, "image/png", cfg { format = "jpeg" })
      assert.is_not_nil(res.path)
      assert.are_equal("image/jpeg", res.mime)
      assert.are_equal(10, vim.uv.fs_stat(res.path).size)
      tmp_files[#tmp_files + 1] = res.path
    end)

    it("passes stderr on tool failure", function()
      stub_executables { sips = true }
      stub_system(0, 1)
      local input = make_file(100, ".png")
      tmp_files[#tmp_files + 1] = input
      local res = run(input, "image/png", cfg())
      assert.is_nil(res.path)
      assert.are_equal("boom", res.err)
    end)

    it("skips silently when the output is not smaller than the input", function()
      stub_executables { sips = true }
      stub_system(200, 0) -- larger than the 100-byte input
      local input = make_file(100, ".png")
      tmp_files[#tmp_files + 1] = input
      local res = run(input, "image/png", cfg())
      assert.is_nil(res.path)
      assert.is_nil(res.err)
    end)

    it("reports spawn failures", function()
      stub_executables { sips = true }
      vim.system = function()
        error "spawn sips ENOENT"
      end
      local input = make_file(100, ".png")
      tmp_files[#tmp_files + 1] = input
      local res = run(input, "image/png", cfg())
      assert.is_nil(res.path)
      assert.truthy(res.err:match "spawn sips")
    end)
  end)

  describe("config defaults", function()
    it("ships the documented defaults", function()
      local c = Config.options.prompt.image_compress
      assert.are_equal(true, c.enable)
      assert.are_equal(1568, c.max_dimension)
      assert.are_equal(80, c.quality)
      assert.are_equal("keep", c.format)
      assert.are_equal("auto", c.tool)
      assert.are_equal("all", c.scope)
    end)
  end)
end)
