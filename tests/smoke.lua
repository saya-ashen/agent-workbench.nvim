local Rpc = require("pi.rpc")

Rpc.start = function(self)
    self._job_id = 1
    return true
end
Rpc.send = function(self, _, callback)
    if callback then
        callback({ type = "response", success = true, data = {} })
    end
    return true
end
Rpc.stop = function(self)
    self._job_id = nil
    self._pending = {}
end

local ok, err = pcall(function()
    require("pi").setup({ auto_start_session = false })
    require("pi").show({ layout = "side" })
    local session = assert(require("pi.sessions.manager").get(), "session missing")
    assert(vim.api.nvim_buf_is_valid(session.history_buf), "History buffer missing")
    assert(vim.api.nvim_buf_is_valid(session.chat:prompt_buf()), "prompt buffer missing")
end)

if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cq 1")
else
    vim.cmd("qa!")
end
