local Chat = require("agent-workbench.ui.chat.init")
local Config = require("agent-workbench.config")
local Output = require("agent-workbench.ui.chat.terminal.output")
local Completion = require("agent-workbench.ui.chat.terminal.shell.completion")

local next_session_id = 990

local function new_chat()
    next_session_id = next_session_id + 1
    Config.options.prompt.draft.enabled = false
    local sent = {}
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "buffer", {
        send = function(command)
            sent[#sent + 1] = command
            return true
        end,
    }, nil, next_session_id, vim.uv.cwd())
    chat:show()
    return chat, sent
end

local function delete_chat(chat)
    chat:destroy()
    if #vim.api.nvim_list_wins() == 1 then
        vim.cmd("new")
    end
    chat:hide()
    for _, buf in ipairs({ chat:history_buf(), chat:prompt_buf(), chat:attachments_buf() }) do
        if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
end

local function enter_worksheet(chat)
    chat._prompt:set_text("!!")
    chat:submit()
    assert.is_true(chat._prompt:is_terminal_display())
end

local function buffer_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function wait_finished(chat)
    return vim.wait(5000, function()
        return not chat._worksheet:running()
    end, 20)
end

local function run_cell(chat, command)
    chat._worksheet:set_input(command)
    local ok, err = chat._worksheet:execute_current()
    assert.is_true(ok, err)
    assert.is_true(wait_finished(chat))
end

---@param completion_output? string
local function fake_session(completion_output)
    return {
        alive = function()
            return true
        end,
        interrupt = function(self)
            self.interrupted = true
        end,
        run = function(self, command)
            self.command = command
            return true
        end,
        complete = function(self, commandline, callback)
            self.completion_commandline = commandline
            callback(completion_output or "")
            return true
        end,
        stop = function() end,
    }
end

local function find_map(buf, mode, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if map.lhs == lhs then
            return map
        end
    end
    return nil
end

describe("shell worksheet", function()
    it("runs an initial !! command once and places the cursor after the prompt", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local chat = new_chat()
        local command = "printf '__PI_ONCE__\\n'"
        chat._prompt:set_text("!!" .. command)
        chat:submit()
        assert.is_true(wait_finished(chat))

        local worksheet = chat._worksheet
        local block = assert(worksheet._blocks[1])
        assert.are.equal(1, #worksheet._blocks)
        assert.are.equal(
            command,
            vim.api.nvim_buf_get_lines(chat:prompt_buf(), block.command_row - 1, block.command_row, false)[1]
        )
        assert.are.same(
            { "__PI_ONCE__" },
            vim.api.nvim_buf_get_lines(chat:prompt_buf(), block.output_start - 1, block.output_end, false)
        )
        assert.are.equal(
            "",
            vim.api.nvim_buf_get_lines(chat:prompt_buf(), block.output_end, block.output_end + 1, false)[1]
        )
        assert.are.equal(block.output_end + 2, worksheet._current_start)
        assert.are.same({ worksheet._current_start, 2 }, vim.api.nvim_win_get_cursor(chat:prompt_win()))
        local prompt_marks = vim.api.nvim_buf_get_extmarks(
            chat:prompt_buf(),
            vim.api.nvim_get_namespaces()["pi-shell-worksheet-prompt"],
            0,
            -1,
            { details = true }
        )
        assert.are.equal(2, #prompt_marks)
        assert.are.same({ block.command_row - 1, worksheet._current_start - 1 }, {
            prompt_marks[1][2],
            prompt_marks[2][2],
        })
        assert.are.same({ { "❯ ", "PiShellPrompt" } }, prompt_marks[1][4].virt_text)
        delete_chat(chat)
    end)

    it("decorates ANSI output and paths without changing result text", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("styled output")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("\27[31mRED\27[0m tests\r\n")
        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))

        local block = worksheet._blocks[#worksheet._blocks]
        assert.are.same(
            { "RED tests" },
            vim.api.nvim_buf_get_lines(chat:prompt_buf(), block.output_start - 1, block.output_end, false)
        )
        assert.is_true(vim.tbl_contains(
            vim.tbl_map(function(span)
                return span.hl_group
            end, block.decorations.spans),
            "Directory"
        ))
        local marks = vim.api.nvim_buf_get_extmarks(
            chat:prompt_buf(),
            Output.namespace(),
            { block.output_start - 1, 0 },
            { block.output_end - 1, -1 },
            { details = true }
        )
        assert.is_true(#marks >= 2)
        local mark_count = #marks
        worksheet:set_input("next command")
        assert.are.equal(mark_count, #vim.api.nvim_buf_get_extmarks(chat:prompt_buf(), Output.namespace(), 0, -1, {}))
        chat:leave_terminal()
        assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(chat:prompt_buf(), Output.namespace(), 0, -1, {}))
        chat:focus_terminal()
        assert.are.equal(mark_count, #vim.api.nvim_buf_get_extmarks(chat:prompt_buf(), Output.namespace(), 0, -1, {}))
        delete_chat(chat)
    end)

    it("runs the current cell from Insert <CR> and keeps <S-CR> for newlines", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        local session = fake_session()
        worksheet._session = session
        worksheet:set_input("echo from-insert-enter")

        local enter = assert(find_map(chat:prompt_buf(), "i", "<CR>"))
        assert.are.equal("Run π shell cell", enter.desc)
        enter.callback()
        assert.is_true(vim.wait(1000, function()
            return session.command ~= nil
        end, 10))
        assert.are.equal("echo from-insert-enter", session.command)
        assert.are.equal("<CR>", assert(find_map(chat:prompt_buf(), "i", "<S-CR>")).callback())

        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))
        delete_chat(chat)
    end)

    it("keeps fish state across editable command cells outside agent RPC", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local chat, sent = new_chat()
        chat._prompt:set_text("!!set -g PI_WORKSHEET_TEST kept")
        chat:submit()
        local buf = chat:prompt_buf()
        assert.is_true(wait_finished(chat))

        run_cell(chat, "cd /tmp; function pi_worksheet_fn; echo function-ok; end")
        assert.are.equal("/tmp", chat._worksheet._cwd)
        run_cell(chat, "printf '__PI_WORKSHEET__%s\\n' $PI_WORKSHEET_TEST; pwd; pi_worksheet_fn")
        run_cell(chat, "for value in one two\n    echo multi-$value\nend")

        local text = buffer_text(buf)
        assert.is_true(text:find("__PI_WORKSHEET__kept", 1, true) ~= nil)
        assert.is_true(text:find("/tmp", 1, true) ~= nil)
        assert.is_true(text:find("function-ok", 1, true) ~= nil)
        assert.is_true(text:find("multi-one", 1, true) ~= nil)
        assert.are.equal(0, #sent)
        assert.are.equal(chat:history_buf(), vim.api.nvim_win_get_buf(chat._layout:history_win()))
        delete_chat(chat)
    end)

    it("completes from the persistent fish session", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local chat = new_chat()
        enter_worksheet(chat)
        run_cell(
            chat,
            "function pi_worksheet_complete_cmd; end; complete -c pi_worksheet_complete_cmd -l custom -d 'custom option'"
        )

        local output
        local ok, err = chat._worksheet._session:complete("pi_worksheet_complete_cmd --cu", function(value)
            output = value
        end)
        assert.is_true(ok, err)
        assert.is_true(vim.wait(5000, function()
            return output ~= nil
        end, 20))
        local item = vim.tbl_filter(function(candidate)
            return candidate.word == "--custom"
        end, Completion.parse(output))[1]
        assert.is_not_nil(item)
        assert.are.equal("[fish] custom option", item.menu)
        delete_chat(chat)
    end)

    it("returns descriptions for fish command options", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local chat = new_chat()
        enter_worksheet(chat)

        local output
        local ok, err = chat._worksheet._session:complete("ls -", function(value)
            output = value
        end)
        assert.is_true(ok, err)
        assert.is_true(vim.wait(5000, function()
            return output ~= nil
        end, 20))
        local item = vim.tbl_filter(function(candidate)
            return candidate.word == "-a"
        end, Completion.parse(output))[1]
        assert.is_not_nil(item)
        assert.is_true(item.menu ~= "[fish]")
        delete_chat(chat)
    end)

    it("adapts fish candidates to Blink completion items", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local buf = chat:prompt_buf()
        chat._worksheet._session = fake_session("--custom\tcustom option\r\n")
        chat._worksheet:set_input("cmd --cu")
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, #"  cmd --cu" })
        vim.b[buf].pi_shell_blink_completion = true
        local omnifunc = require("agent-workbench.completion.omnifunc").completefunc
        assert.are.equal(-3, omnifunc(1, ""))
        assert.are.same({}, omnifunc(0, "@file"))

        local response
        local source = require("agent-workbench.completion.shell").new()
        assert.is_true(source:enabled())
        source:get_completions({ bufnr = buf, cursor = { 1, #"  cmd --cu" } }, function(value)
            response = value
        end)
        local item = assert(response.items[1])
        assert.are.equal("--custom", item.label)
        assert.are.equal("custom option", item.labelDetails.description)
        assert.are.same({ kind = "plaintext", value = "custom option" }, item.documentation)
        assert.are.same({ line = 0, character = 6 }, item.textEdit.range.start)
        assert.are.same({ line = 0, character = 10 }, item.textEdit.range["end"])
        delete_chat(chat)
    end)

    it("prioritizes the current short option in Blink", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local buf = chat:prompt_buf()
        chat._worksheet._session = fake_session("-la1\tlist one file per line\r\n")
        chat._worksheet:set_input("cmd -la")
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, #"  cmd -la" })
        vim.b[buf].pi_shell_blink_completion = true

        local response
        require("agent-workbench.completion.shell")
            .new()
            :get_completions({ bufnr = buf, cursor = { 1, #"  cmd -la" } }, function(value)
                response = value
            end)
        assert.are.equal("-la", response.items[1].label)
        assert.are.equal(1000, response.items[1].score_offset)
        delete_chat(chat)
    end)

    it("completes immediately after command whitespace", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local buf = chat:prompt_buf()
        local session = fake_session("AGENTS.md\r\nlua/\r\n")
        chat._worksheet._session = session
        chat._worksheet:set_input("ls ")
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, #"  ls " })
        vim.b[buf].pi_shell_blink_completion = true

        local response
        local source = require("agent-workbench.completion.shell").new()
        assert.is_true(vim.tbl_contains(source:get_trigger_characters(), " "))
        source:get_completions({ bufnr = buf, cursor = { 1, #"  ls " } }, function(value)
            response = value
        end)
        assert.are.equal("ls ", session.completion_commandline)
        assert.are.same(
            { "AGENTS.md", "lua/" },
            vim.tbl_map(function(item)
                return item.label
            end, response.items)
        )
        assert.are.same({ line = 0, character = 5 }, response.items[1].textEdit.range.start)
        assert.are.same({ line = 0, character = 5 }, response.items[1].textEdit.range["end"])
        delete_chat(chat)
    end)

    it("keeps an exact command candidate while hiding structural Fish descriptions", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local buf = chat:prompt_buf()
        chat._worksheet._session = fake_session("ls\tList directory contents\r\nlscpu\tcommand link\r\n")
        chat._worksheet:set_input("ls")
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, #"  ls" })
        vim.b[buf].pi_shell_blink_completion = true

        local response
        require("agent-workbench.completion.shell")
            .new()
            :get_completions({ bufnr = buf, cursor = { 1, #"  ls" } }, function(value)
                response = value
            end)
        assert.are.equal("ls", response.items[1].label)
        assert.are.equal("List directory contents", response.items[1].labelDetails.description)
        assert.are.equal("lscpu", response.items[2].label)
        assert.is_nil(response.items[2].labelDetails)
        assert.is_nil(response.items[2].documentation)
        delete_chat(chat)
    end)

    it("leaves navigation keys unmapped and restores compose mappings", function()
        local chat = new_chat()
        local buf = chat:prompt_buf()
        vim.keymap.set("n", "gZ", function() end, { buffer = buf, desc = "user π mapping" })
        vim.keymap.set("n", "i", function() end, { buffer = buf, desc = "user edit mapping" })
        vim.keymap.set("n", "q", function() end, { buffer = buf, desc = "user q mapping" })
        vim.keymap.set("n", "<C-c>", function() end, { buffer = buf, desc = "user interrupt mapping" })
        vim.keymap.set("n", "<C-g>p", function() end, { buffer = buf, desc = "user return mapping" })
        vim.keymap.set("i", "<CR>", function() end, { buffer = buf, desc = "user insert return mapping" })
        vim.keymap.set("i", "<S-CR>", function() end, { buffer = buf, desc = "user newline mapping" })
        vim.keymap.set("i", "<C-d>", function() end, { buffer = buf, desc = "user eof mapping" })
        vim.keymap.set("i", "<Tab>", function() end, { buffer = buf, desc = "user tab mapping" })
        vim.keymap.set("i", "<S-Tab>", function() end, { buffer = buf, desc = "user backtab mapping" })
        vim.b[buf].completion = true
        enter_worksheet(chat)

        for _, lhs in ipairs({ "<Esc>", "<C-p>", "<C-n>", "<Up>", "<Down>", "<C-H>", "<C-J>", "<C-K>", "<C-L>" }) do
            assert.is_nil(find_map(buf, "n", lhs), lhs .. " must not be buffer-local in worksheet Normal mode")
            assert.is_nil(find_map(buf, "i", lhs), lhs .. " must not be buffer-local in worksheet Insert mode")
        end
        assert.are.equal("Run π shell cell", assert(find_map(buf, "i", "<CR>")).desc)
        assert.are.equal("Insert newline in π shell cell", assert(find_map(buf, "i", "<S-CR>")).desc)
        assert.are.equal("Return from empty π shell input", assert(find_map(buf, "i", "<C-D>")).desc)
        assert.are.equal("Interrupt running π shell command", assert(find_map(buf, "n", "<C-C>")).desc)
        assert.are.equal("Select next π shell completion", assert(find_map(buf, "i", "<Tab>")).desc)
        assert.are.equal("Select previous π shell completion", assert(find_map(buf, "i", "<S-Tab>")).desc)
        assert.is_true(vim.b[buf].completion)
        assert.is_true(vim.b[buf].pi_prompt_completion)
        assert.are.equal("Run π shell cell", assert(find_map(buf, "n", "<CR>")).desc)
        assert.are.equal("Edit current π shell input", assert(find_map(buf, "n", "i")).desc)
        assert.are.equal("user π mapping", assert(find_map(buf, "n", "gZ")).desc)
        assert.are.equal("Return to π compose prompt from worksheet", assert(find_map(buf, "n", "q")).desc)

        chat._worksheet:set_input("draft cell")
        vim.bo[buf].undolevels = -1
        vim.bo[buf].undolevels = 1000
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, 0 })
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("normal! A plus")
            vim.cmd("undo")
        end)
        assert.are.same({ "  draft cell" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        chat:focus_terminal()
        assert.are.same({ "  draft cell" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

        chat:leave_terminal()
        assert.are.equal("user insert return mapping", assert(find_map(buf, "i", "<CR>")).desc)
        assert.are.equal("user newline mapping", assert(find_map(buf, "i", "<S-CR>")).desc)
        assert.are.equal("user eof mapping", assert(find_map(buf, "i", "<C-D>")).desc)
        assert.are.equal("user tab mapping", assert(find_map(buf, "i", "<Tab>")).desc)
        assert.are.equal("user backtab mapping", assert(find_map(buf, "i", "<S-Tab>")).desc)
        assert.is_true(vim.b[buf].completion)
        assert.is_not_nil(find_map(buf, "i", "<C-P>"))
        assert.is_not_nil(find_map(buf, "i", "<C-N>"))
        assert.are.equal("user q mapping", assert(find_map(buf, "n", "q")).desc)
        assert.are.equal("user interrupt mapping", assert(find_map(buf, "n", "<C-C>")).desc)
        assert.are.equal("user return mapping", assert(find_map(buf, "n", "<C-G>p")).desc)
        assert.are.equal("user edit mapping", assert(find_map(buf, "n", "i")).desc)

        chat._prompt._use_shell_blink = true
        enter_worksheet(chat)
        assert.is_true(vim.b[buf].pi_shell_blink_completion)
        assert.is_true(vim.b[buf].pi_prompt_completion)
        assert.are.equal("user tab mapping", assert(find_map(buf, "i", "<Tab>")).desc)
        assert.are.equal("user backtab mapping", assert(find_map(buf, "i", "<S-Tab>")).desc)
        chat:leave_terminal()
        delete_chat(chat)
    end)

    it("redirects Normal edit keys from history to the current input", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("first command")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("result\r\n")
        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))
        worksheet:set_input("draft command")

        local buf = chat:prompt_buf()
        local win = chat:prompt_win()
        vim.cmd("stopinsert")
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        for _, key in ipairs({ "i", "I", "a", "A", "o", "O", "c", "C" }) do
            assert.are.equal("Edit current π shell input", assert(find_map(buf, "n", key)).desc)
        end

        local edit = assert(find_map(buf, "n", "i"))
        assert.are.equal("", edit.callback())
        assert.is_true(vim.wait(1000, function()
            local cursor = vim.api.nvim_win_get_cursor(win)
            return cursor[1] == vim.api.nvim_buf_line_count(buf) and cursor[2] == #"  draft command"
        end, 10))
        assert.is_true(vim.bo[buf].modifiable)
        assert.are.equal("i", edit.callback())
        vim.cmd("stopinsert")
        delete_chat(chat)
    end)

    it("uses Normal Ctrl-C to interrupt only while a command runs", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        local session = fake_session()
        worksheet._session = session
        local ctrl_c = assert(find_map(chat:prompt_buf(), "n", "<C-C>"))
        assert.are.equal("Interrupt running π shell command", ctrl_c.desc)

        assert.are.equal("<C-c>", ctrl_c.callback())
        assert.is_nil(session.interrupted)

        worksheet:set_input("sleep 100")
        assert.is_true(worksheet:execute_current())
        assert.are.equal("", ctrl_c.callback())
        assert.is_true(vim.wait(1000, function()
            return session.interrupted == true
        end, 10))
        worksheet:_finish(130, 1)
        assert.is_true(wait_finished(chat))
        delete_chat(chat)
    end)

    it("returns to compose on Ctrl-D only from empty current input", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("first command")
        assert.is_true(worksheet:execute_current())
        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))

        local buf = chat:prompt_buf()
        local win = chat:prompt_win()
        local ctrl_d = assert(find_map(buf, "n", "<C-D>"))
        assert.are.equal("Return from empty π shell input", ctrl_d.desc)
        assert.are.equal("Return from empty π shell input", assert(find_map(buf, "i", "<C-D>")).desc)

        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        assert.are.equal("<C-d>", ctrl_d.callback())
        assert.is_true(chat._prompt:is_terminal_display())

        worksheet:set_input("draft")
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), #"  draft" })
        assert.are.equal("<C-d>", ctrl_d.callback())
        assert.is_true(chat._prompt:is_terminal_display())

        worksheet:set_input("")
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), #"  " })
        assert.are.equal("", ctrl_d.callback())
        assert.is_true(vim.wait(1000, function()
            return not chat._prompt:is_terminal_display()
        end, 10))
        delete_chat(chat)
    end)

    it("preserves worksheet text and undo across hide, layout, and compose switches", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local buf = chat:prompt_buf()
        chat._worksheet:set_input("base")
        vim.bo[buf].undolevels = -1
        vim.bo[buf].undolevels = 1000
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, 0 })
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("normal! A edited")
        end)

        chat:hide()
        chat:show()
        assert.are.same({ "  base edited" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        chat:toggle_layout()
        assert.are.same({ "  base edited" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        chat:leave_terminal()
        chat:focus_terminal()
        assert.are.same({ "  base edited" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("undo")
        end)
        assert.are.same({ "  base" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        delete_chat(chat)
    end)

    it("preserves user-created manual folds across view suspension", function()
        local chat = new_chat()
        enter_worksheet(chat)
        chat._worksheet:set_input("one\ntwo\nthree")
        vim.api.nvim_win_call(chat:prompt_win(), function()
            vim.cmd("1,3fold")
            vim.cmd("1foldopen")
        end)
        chat:hide()
        chat:show()
        assert.is_true(vim.fn.foldlevel(1) > 0)
        assert.are.equal(-1, vim.fn.foldclosed(1))
        delete_chat(chat)
    end)

    it("buffers output while a prompt request owns the Prompt buffer", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("echo request-output")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("before-request\r\n")
        local buf = chat:prompt_buf()
        vim.bo[buf].undolevels = -1
        vim.bo[buf].undolevels = 1000
        local draft_row = worksheet._current_start
        vim.api.nvim_buf_set_lines(buf, draft_row - 1, draft_row, false, { "  next-draft" })
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { draft_row, #"  next-draft" })

        local chosen
        assert.is_true(chat:present_prompt_request({
            id = "shell-request",
            kind = "confirm",
            title = "Continue?",
            options = { "Yes", "No" },
            selected = 1,
            callback = function(value)
                chosen = value
            end,
        }))
        worksheet:_append_output("after-request\r\n")
        worksheet:_finish(0, 12)
        assert.is_true(wait_finished(chat))
        assert.is_true(chat._prompt:is_request_mode())
        assert.is_false(buffer_text(chat:prompt_buf()):find("before-request", 1, true) ~= nil)

        chat._prompt:confirm_request()
        assert.are.equal("Yes", chosen)
        assert.is_true(chat._prompt:is_terminal_display())
        local text = buffer_text(chat:prompt_buf())
        assert.is_true(text:find("before-request", 1, true) ~= nil)
        assert.is_true(text:find("after-request", 1, true) ~= nil)
        assert.are.equal("  next-draft", vim.api.nvim_get_current_line())
        assert.are.equal("Run π shell cell", assert(find_map(chat:prompt_buf(), "n", "<CR>")).desc)
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("undo")
        end)
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        assert.is_true(buffer_text(buf):find("next-draft", 1, true) ~= nil)
        assert.is_true(buffer_text(buf):find("before-request", 1, true) ~= nil)
        delete_chat(chat)
    end)

    it("protects completed cells while keeping the current input editable", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("protected")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("immutable-output\r\n")
        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))

        local buf = chat:prompt_buf()
        local block = worksheet._blocks[1]
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { block.output_start, 0 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        assert.is_false(vim.bo[buf].modifiable)
        assert.is_false(
            pcall(vim.api.nvim_buf_set_lines, buf, block.output_start - 1, block.output_start, false, { "changed" })
        )

        vim.api.nvim_win_set_cursor(chat:prompt_win(), { worksheet._current_start, 2 })
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
        assert.is_true(vim.bo[buf].modifiable)
        vim.api.nvim_buf_call(buf, function()
            vim.cmd("normal! dgg")
        end)
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        assert.are.equal("protected", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
        assert.are.equal(
            "immutable-output",
            vim.api.nvim_buf_get_lines(buf, block.output_start - 1, block.output_start, false)[1]
        )
        assert.are.equal("  ", vim.api.nvim_get_current_line())

        vim.api.nvim_buf_call(buf, function()
            vim.cmd("normal! Aeditable")
            vim.cmd("undo")
        end)
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        assert.are.equal("  ", vim.api.nvim_get_current_line())
        assert.are.equal(
            "immutable-output",
            vim.api.nvim_buf_get_lines(buf, block.output_start - 1, block.output_start, false)[1]
        )
        delete_chat(chat)
    end)

    it("preserves intentional trailing blank output lines", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("blank output")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("x\r\n\r\n")
        worksheet:_finish(0, 1)
        assert.is_true(wait_finished(chat))
        local block = worksheet._blocks[#worksheet._blocks]
        assert.are.same(
            { "x", "" },
            vim.api.nvim_buf_get_lines(chat:prompt_buf(), block.output_start - 1, block.output_end, false)
        )
        delete_chat(chat)
    end)

    it("keeps result folds open until the user closes them", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("success")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output(table.concat(vim.tbl_map(tostring, vim.fn.range(1, 10)), "\r\n") .. "\r\n")
        worksheet:_finish(0, 25)
        assert.is_true(wait_finished(chat))
        local succeeded = worksheet._blocks[#worksheet._blocks]
        assert.is_true(vim.fn.foldlevel(succeeded.output_start) > 0)
        assert.are.equal(-1, vim.fn.foldclosed(succeeded.output_start))
        vim.api.nvim_win_call(chat:prompt_win(), function()
            vim.cmd(("silent! %dfoldclose"):format(succeeded.output_start))
        end)
        assert.are.equal(succeeded.output_start, vim.fn.foldclosed(succeeded.output_start))
        assert.is_true(vim.fn.foldtextresult(succeeded.output_start):find("exit 0", 1, true) ~= nil)

        worksheet:set_input("failure")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output("failed\r\nline\r\n")
        worksheet:_finish(2, 10)
        assert.is_true(wait_finished(chat))
        local failed = worksheet._blocks[#worksheet._blocks]
        assert.is_true(vim.fn.foldlevel(failed.output_start) > 0)
        assert.are.equal(-1, vim.fn.foldclosed(failed.output_start))
        delete_chat(chat)
    end)

    it("does not steal the cursor when background output completes away from bottom", function()
        local chat = new_chat()
        enter_worksheet(chat)
        local worksheet = chat._worksheet
        worksheet._session = fake_session()
        worksheet:set_input("first")
        assert.is_true(worksheet:execute_current())
        worksheet:_append_output(table.concat(vim.tbl_map(tostring, vim.fn.range(1, 20)), "\r\n") .. "\r\n")
        worksheet:_finish(1, 5)
        assert.is_true(wait_finished(chat))

        worksheet:set_input("second")
        assert.is_true(worksheet:execute_current())
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { 1, 0 })
        vim.api.nvim_win_call(chat:prompt_win(), function()
            vim.cmd("normal! zt")
        end)
        worksheet:_append_output("background\r\n")
        worksheet:_finish(0, 5)
        assert.is_true(wait_finished(chat))
        assert.are.equal(1, vim.api.nvim_win_get_cursor(chat:prompt_win())[1])

        worksheet:set_input("third")
        assert.is_true(worksheet:execute_current())
        local next_row = worksheet._current_start
        vim.api.nvim_buf_set_lines(chat:prompt_buf(), next_row - 1, next_row, false, { "  typed-next" })
        vim.api.nvim_win_set_cursor(chat:prompt_win(), { next_row, #"  typed-next" })
        worksheet:_append_output("third-output\r\n")
        worksheet:_finish(0, 5)
        assert.is_true(wait_finished(chat))
        assert.are.equal("  typed-next", vim.api.nvim_get_current_line())
        delete_chat(chat)
    end)

    it("interrupts fish and accepts another command", function()
        if vim.fn.executable("fish") ~= 1 then
            return
        end
        local chat = new_chat()
        enter_worksheet(chat)
        chat._worksheet:set_input("sleep 10")
        assert.is_true(chat._worksheet:execute_current())
        vim.wait(100)
        chat._worksheet:interrupt()
        assert.is_true(wait_finished(chat))
        run_cell(chat, "echo after-interrupt")
        assert.is_true(buffer_text(chat:prompt_buf()):find("after-interrupt", 1, true) ~= nil)
        delete_chat(chat)
    end)
end)
