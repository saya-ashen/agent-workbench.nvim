--- Tests for the stale-while-revalidate file cache (pi.cache.files).

describe("files cache", function()
    local FilesCache = require("pi.cache.files")
    local original_cwd = vim.fn.getcwd()
    local dir

    --- Create a git repo with the given relative file paths and cd into it.
    ---@param files string[]
    ---@return string repo directory
    local function make_repo(files)
        local d = vim.fn.tempname()
        vim.fn.mkdir(d, "p")
        vim.system({ "git", "init", "-q", d }):wait()
        for _, f in ipairs(files) do
            vim.fn.writefile({ "x" }, d .. "/" .. f)
        end
        vim.cmd("cd " .. vim.fn.fnameescape(d))
        -- getcwd() resolves macOS tempdir symlinks (/var → /private/var),
        -- tempname() does not; the cache keys on getcwd(), so hand the
        -- resolved form back to the specs.
        return vim.fn.getcwd()
    end

    --- Wait until cond() is true, pumping the event loop (so uv callbacks
    --- and vim.schedule'd code run). Fails the test on timeout.
    ---@param cond fun(): boolean
    local function wait_for(cond)
        assert.True(
            vim.wait(3000, cond, 5),
            "timed out waiting for condition"
        )
    end

    before_each(function()
        FilesCache._reset()
    end)

    after_each(function()
        FilesCache._reset()
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        if dir then
            vim.fn.delete(dir, "rf")
            dir = nil
        end
    end)

    it("cold list() fetches synchronously and populates the cache", function()
        dir = make_repo({ "a.txt" })
        local files = FilesCache.list()
        assert.same({ "a.txt" }, files)
        local c = FilesCache._cache()
        assert.is_not_nil(c)
        assert.same(dir, c.cwd)
        assert.True(c.map["a.txt"])
        -- A cold fetch is synchronous: no async refresh was spawned.
        assert.same(0, FilesCache._refresh_spawns())
    end)

    it("fresh list() returns the cache without spawning a refresh", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()
        vim.fn.writefile({ "x" }, dir .. "/b.txt")
        assert.same({ "a.txt" }, FilesCache.list())
        assert.same(0, FilesCache._refresh_spawns())
    end)

    it("expired list() returns stale data immediately, then refreshes async", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()

        vim.fn.writefile({ "x" }, dir .. "/b.txt")
        FilesCache._expire()

        -- First call after expiry: stale result, refresh kicked off.
        assert.same({ "a.txt" }, FilesCache.list())
        assert.same(1, FilesCache._refresh_spawns())

        -- The background refresh eventually picks up b.txt.
        wait_for(function()
            return vim.tbl_contains(FilesCache.list(), "b.txt")
        end)

        -- Cache is fresh again: no further spawns on subsequent calls.
        assert.same(1, FilesCache._refresh_spawns())
        assert.same({ "a.txt", "b.txt" }, FilesCache.list())
    end)

    it("single-flight: many expired calls spawn only one refresh", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()
        FilesCache._expire()
        for _ = 1, 10 do
            FilesCache.list()
        end
        assert.same(1, FilesCache._refresh_spawns())
        wait_for(function()
            return FilesCache._cache() and FilesCache._cache().timestamp > 0
        end)
    end)

    it("exists() never blocks on a cold cache", function()
        dir = make_repo({ "a.txt" })

        -- No cache yet: answers from the on-disk fallback and kicks off an
        -- async refresh instead of blocking on git.
        assert.True(FilesCache.exists("a.txt"))
        assert.False(FilesCache.exists("nope.txt"))
        -- The refresh cannot have landed yet (no event loop turn since).
        assert.is_nil(FilesCache._cache())
        assert.same(1, FilesCache._refresh_spawns())

        -- The async refresh populates the cache in the background.
        wait_for(function()
            return FilesCache._cache() ~= nil
        end)
        assert.True(FilesCache.exists("a.txt"))
    end)

    it("exists() kicks a refresh on an expired cache", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()
        FilesCache._expire()
        assert.True(FilesCache.exists("a.txt")) -- stale map still has it
        assert.same(1, FilesCache._refresh_spawns())
    end)

    it("cwd change triggers a synchronous cold fetch for the new cwd", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()

        local dir2 = vim.fn.tempname()
        vim.fn.mkdir(dir2, "p")
        vim.system({ "git", "init", "-q", dir2 }):wait()
        vim.fn.writefile({ "x" }, dir2 .. "/c.txt")
        vim.cmd("cd " .. vim.fn.fnameescape(dir2))
        dir2 = vim.fn.getcwd() -- resolved, same form the cache keys on

        local files = FilesCache.list()
        assert.same({ "c.txt" }, files)
        assert.same(dir2, FilesCache._cache().cwd)

        vim.fn.delete(dir2, "rf")
    end)

    it("invalidate() forces a synchronous refetch on next list()", function()
        dir = make_repo({ "a.txt" })
        FilesCache.list()
        vim.fn.writefile({ "x" }, dir .. "/b.txt")

        FilesCache.invalidate()
        assert.is_nil(FilesCache._cache())
        assert.same({ "a.txt", "b.txt" }, FilesCache.list())
        assert.same(0, FilesCache._refresh_spawns())
    end)

    it("falls back to glob in non-git directories", function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir .. "/sub", "p")
        vim.fn.writefile({ "x" }, dir .. "/d.txt")
        vim.fn.writefile({ "x" }, dir .. "/sub/e.txt")
        vim.cmd("cd " .. vim.fn.fnameescape(dir))

        local files = FilesCache.list()
        table.sort(files)
        assert.same({ "d.txt", "sub/e.txt" }, files)
    end)
end)
