-- Unit tests for pi.draft (unsent-prompt persistence). Hermetic: every
-- workspace/process path stays under a temporary directory.

describe("pi.draft", function()
    local Draft = require("agent-workbench.draft")
    local root
    local path_for

    local function write_file(path, text)
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        local f = assert(io.open(path, "w"))
        f:write(text)
        f:close()
    end

    before_each(function()
        root = vim.fn.tempname()
        path_for = function(cwd, pid)
            return ("%s/%s/%d.txt"):format(root, vim.fn.sha256(vim.fs.normalize(cwd)), pid)
        end
        Draft._set_path(path_for)
        Draft._reset()
    end)

    after_each(function()
        Draft._set_path(nil)
        Draft._reset()
        vim.fn.delete(root, "rf")
    end)

    describe("persistence", function()
        it("returns nil when there is no draft", function()
            assert.is_nil(Draft.load("/workspace/one"))
        end)

        it("round-trips save/load (multi-line)", function()
            Draft.save("line1\nline2", "/workspace/one")
            assert.are.equal("line1\nline2", Draft.load("/workspace/one"))
        end)

        it("keeps workspaces separate", function()
            Draft.save("one", "/workspace/one")
            Draft.save("two", "/workspace/two")
            assert.are.equal("one", Draft.load("/workspace/one"))
            assert.are.equal("two", Draft.load("/workspace/two"))
        end)

        it("save('') clears only the current workspace draft", function()
            Draft.save("one", "/workspace/one")
            Draft.save("two", "/workspace/two")
            Draft.save("", "/workspace/one")
            assert.is_nil(Draft.load("/workspace/one"))
            assert.are.equal("two", Draft.load("/workspace/two"))
        end)

        it("clear removes the draft", function()
            Draft.save("x", "/workspace/one")
            Draft.clear("/workspace/one")
            assert.is_nil(Draft.load("/workspace/one"))
        end)
    end)

    describe("prompt integration", function()
        it("keeps prompt saves scoped by constructor cwd", function()
            local Attachments = require("agent-workbench.ui.chat.attachments")
            local Prompt = require("agent-workbench.ui.chat.prompt")
            local first_attachments = Attachments.new()
            local first = Prompt.new(9001, first_attachments, "/workspace/one")
            first:set_text("workspace one")
            first:_save_draft()

            local second_attachments = Attachments.new()
            local second = Prompt.new(9002, second_attachments, "/workspace/two")
            assert.are.equal("", second:text())
            second:set_text("workspace two")
            second:_save_draft()

            assert.are.equal("workspace one", Draft.load("/workspace/one"))
            assert.are.equal("workspace two", Draft.load("/workspace/two"))
            for _, buf in ipairs({ first:buf(), first_attachments:buf(), second:buf(), second_attachments:buf() }) do
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end)

        it("never persists terminal grid contents as compose draft", function()
            local Config = require("agent-workbench.config")
            local Attachments = require("agent-workbench.ui.chat.attachments")
            local Prompt = require("agent-workbench.ui.chat.prompt")
            local draft_enabled = Config.options.prompt.draft.enabled
            Config.options.prompt.draft.enabled = true
            local attachments = Attachments.new()
            local prompt = Prompt.new(9003, attachments, "/workspace/terminal")
            prompt:set_text("!!")
            prompt:_save_draft()
            assert.are.equal("!!", Draft.load("/workspace/terminal"))

            assert.is_true(prompt:enter_terminal(""))
            prompt:_set_lines({ "shell output must not become a draft" })
            prompt:_save_draft()
            assert.is_nil(Draft.load("/workspace/terminal"))
            assert.is_true(prompt:leave_terminal())
            assert.are.equal("", prompt:text())

            prompt:set_text("unsent compose draft")
            prompt:_save_draft()
            assert.is_true(prompt:enter_terminal(nil, true))
            prompt:_set_lines({ "new shell output" })
            prompt:_save_draft()
            assert.are.equal("unsent compose draft", Draft.load("/workspace/terminal"))
            assert.is_true(prompt:leave_terminal())
            assert.are.equal("unsent compose draft", prompt:text())

            Config.options.prompt.draft.enabled = draft_enabled
            for _, buf in ipairs({ prompt:buf(), attachments:buf() }) do
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end)
    end)

    describe("restore_once", function()
        it("returns a workspace draft on the first call only", function()
            Draft.save("my draft", "/workspace/one")
            assert.are.equal("my draft", Draft.restore_once("/workspace/one"))
            assert.is_nil(Draft.restore_once("/workspace/one"))
        end)

        it("allows one restore per workspace", function()
            Draft.save("one", "/workspace/one")
            Draft.save("two", "/workspace/two")
            assert.are.equal("one", Draft.restore_once("/workspace/one"))
            assert.are.equal("two", Draft.restore_once("/workspace/two"))
        end)

        it("claims a draft left by a dead process", function()
            local cwd = "/workspace/one"
            local stale = path_for(cwd, 2147483647)
            write_file(stale, "recover me")

            assert.are.equal("recover me", Draft.restore_once(cwd))
            assert.are.equal(0, vim.fn.filereadable(stale))
            assert.are.equal("recover me", Draft.load(cwd))
        end)

        it("ignores drafts owned by a live process", function()
            local cwd = "/workspace/one"
            local parent_pid = vim.uv.os_getppid()
            write_file(path_for(cwd, parent_pid), "not mine")

            assert.is_nil(Draft.restore_once(cwd))
        end)

        it("returns nil when there is nothing to restore", function()
            assert.is_nil(Draft.restore_once("/workspace/one"))
        end)

        it("_reset allows restoring again (simulates a new process)", function()
            Draft.save("again", "/workspace/one")
            Draft.restore_once("/workspace/one")
            Draft._reset()
            assert.are.equal("again", Draft.restore_once("/workspace/one"))
        end)
    end)
end)
