local Backends = require("agent-workbench.backends")
local Config = require("agent-workbench.config")
local Sessions = require("agent-workbench.sessions.manager")
local Workbench = require("agent-workbench")

local original_select
local instances
local select_calls

local function history_backend(options)
    local backend = {
        closed = false,
        id = options.id,
        list_calls = 0,
        load_calls = 0,
    }
    instances[#instances + 1] = backend

    function backend:capabilities()
        return {
            attachments = false,
            changed_files = false,
            commands = false,
            compaction = false,
            direct_bash = false,
            follow_up = false,
            history = true,
            models = false,
            raw_rpc = false,
            thinking = false,
            tree = false,
        }
    end

    function backend:start(sink)
        self.sink = sink
        return true
    end

    function backend:close()
        self.closed = true
    end

    function backend:prompt()
        return true
    end

    function backend:steer()
        return true
    end

    function backend:stop()
        return true
    end

    function backend:is_running()
        return not self.closed
    end

    function backend:list_history(callback)
        self.list_calls = self.list_calls + 1
        vim.schedule(function()
            callback({
                {
                    id = "chat-history",
                    task_id = "task-history",
                    title = "historical prompt",
                    timestamp = 1787570000,
                    work_dir = options.cwd,
                },
            })
        end)
        return true
    end

    function backend:load_history(item, callback)
        self.load_calls = self.load_calls + 1
        self.loaded_item = item
        vim.schedule(function()
            callback({
                chat_id = item.id,
                task_id = item.task_id,
                messages = {
                    { role = "user", content = "historical prompt", timestamp = 1000 },
                    {
                        role = "assistant",
                        content = { { type = "text", text = "historical answer" } },
                        timestamp = 1001,
                    },
                },
            })
        end)
        return true
    end

    return backend
end

local function wait_for(predicate, message)
    assert(vim.wait(2000, predicate, 10), message)
end

local function rendered(session)
    return table.concat(vim.api.nvim_buf_get_lines(session.chat:history_buf(), 0, -1, false), "\n")
end

describe("backend-owned history", function()
    before_each(function()
        Sessions._reset()
        Backends._reset()
        instances = {}
        select_calls = 0
        original_select = vim.ui.select
        vim.ui.select = function(items, _, callback)
            select_calls = select_calls + 1
            callback(items[1])
        end
        Workbench.register_backend("history-test", history_backend)
        Config.setup({
            backend = "history-test",
            render = { markdown = { enabled = false } },
            prompt = { history = { enabled = false }, draft = { enabled = false } },
        })
    end)

    after_each(function()
        vim.ui.select = original_select
        Sessions._reset()
        Backends._reset()
    end)

    it("resumes backend history into the active Workbench session", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        Workbench.resume_session()

        wait_for(function()
            return instances[1].load_calls == 1 and rendered(session):find("historical answer", 1, true) ~= nil
        end, "backend history was not replayed")
        assert.are.equal(1, instances[1].list_calls)
        assert.are.equal("task-history", instances[1].loaded_item.task_id)
        assert.are.equal(1, #Sessions.list())
        assert.is_truthy(rendered(session):find("historical prompt", 1, true))
    end)

    it("creates a backend session when resume starts without one", function()
        Workbench.resume_session()
        wait_for(function()
            local session = Sessions.get()
            return session and #instances == 1 and rendered(session):find("historical answer", 1, true) ~= nil
        end, "backend history did not create and populate a session")
        assert.are.equal(1, instances[1].list_calls)
        assert.are.equal(1, instances[1].load_calls)
        assert.are.equal(1, select_calls)
    end)

    it("continues the newest backend history item without opening a picker", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        Workbench.continue_session()
        wait_for(function()
            return instances[1].load_calls == 1 and rendered(session):find("historical answer", 1, true) ~= nil
        end, "newest backend history was not continued")
        assert.are.equal(1, instances[1].list_calls)
        assert.are.equal(0, select_calls)
    end)

    it("refuses backend history while the active session is busy", function()
        local session = assert(Sessions.get_or_create({ layout = "buffer" }))
        session.chat:on_agent_start()
        Workbench.resume_session()
        vim.wait(100)
        assert.are.equal(0, instances[1].list_calls)
        assert.are.equal(0, instances[1].load_calls)
        session.chat:on_agent_end()
    end)
end)
