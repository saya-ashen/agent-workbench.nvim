-- Tests for History:sync_pending_queue — reconciliation of the local
-- pending queue with pi's authoritative queue_update payload.
--
-- Semantics (see history.lua):
-- * payload items missing locally are synthesized (additive);
-- * locally tracked entries covered by the payload are kept as-is
--   (preserving display text / image_count);
-- * unmatched local entries are KEPT while active (streaming/compacting):
--   they are mid-delivery (message_start follows) or pre-abort-flush
--   (on_agent_end renders them);
-- * unmatched local entries are SWEPT when idle: no delivery can arrive
--   anymore, so they are ghosts.

local History = require("pi.ui.chat.history")

local TAB = 961

describe("history pending queue sync (queue_update)", function()
    local function setup_history()
        local h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        return h
    end

    local function queue_texts(h)
        local out = {}
        for _, entry in ipairs(h._pending_queue) do
            out[#out + 1] = entry.queue_type .. ":" .. entry.expanded_text
        end
        return out
    end

    it("synthesizes entries for payload items missing locally", function()
        local h = setup_history()
        local counts = {}
        h:set_queue_listener(function(count)
            counts[#counts + 1] = count
        end)

        h:sync_pending_queue({ "steer one" }, { "follow two" }, true)

        assert.are.same({ "steer:steer one", "follow_up:follow two" }, queue_texts(h))
        -- display text falls back to the payload text
        assert.are.equal("steer one", h._pending_queue[1].text)
        assert.are.equal("follow two", h._pending_queue[2].text)
        assert.are.equal(2, counts[#counts])
    end)

    it("keeps rich local entries covered by the payload (no duplication)", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "raw @file display", "expanded @file display", 2)

        h:sync_pending_queue({ "expanded @file display" }, {}, true)

        assert.are.equal(1, #h._pending_queue)
        local entry = h._pending_queue[1]
        assert.are.equal("raw @file display", entry.text) -- display text preserved
        assert.are.equal(2, entry.image_count)
    end)

    it("keeps unmatched local entries while active (mid-delivery / pre-abort)", function()
        local h = setup_history()
        h:add_pending_queue_entry("follow_up", "queued msg", "queued msg")

        -- pi dropped/cleared the queue, but the agent is still running:
        -- removal must be left to message_start / on_agent_end.
        h:sync_pending_queue({}, {}, true)

        assert.are.same({ "follow_up:queued msg" }, queue_texts(h))
    end)

    it("sweeps unmatched local entries when idle (ghost entries)", function()
        local h = setup_history()
        local last_count
        h:set_queue_listener(function(count)
            last_count = count
        end)
        h:add_pending_queue_entry("steer", "ghost", "ghost")
        assert.are.equal(1, #h._pending_queue)

        h:sync_pending_queue({}, {}, false)

        assert.are.equal(0, #h._pending_queue)
        assert.are.equal(0, last_count)
    end)

    it("sweeps only the unmatched entries when idle", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "keep me", "keep me")
        h:add_pending_queue_entry("follow_up", "ghost", "ghost")

        h:sync_pending_queue({ "keep me" }, {}, false)

        assert.are.same({ "steer:keep me" }, queue_texts(h))
    end)

    it("adds only the missing copy for duplicate payload texts", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "dup", "dup")

        h:sync_pending_queue({ "dup", "dup" }, {}, true)

        assert.are.same({ "steer:dup", "steer:dup" }, queue_texts(h))
    end)

    it("tolerates nil and non-string payload items", function()
        local h = setup_history()

        h:sync_pending_queue(nil, nil, false)
        h:sync_pending_queue({ "ok", 42, nil, true }, { {} }, true)

        assert.are.same({ "steer:ok" }, queue_texts(h))
    end)

    it("matches payload texts to the correct queue type", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "same text", "same text")

        -- same text queued as follow_up on pi's side: the steer entry is not
        -- a cover for it, so a follow_up entry must be synthesized.
        h:sync_pending_queue({ "same text" }, { "same text" }, true)

        assert.are.same({ "steer:same text", "follow_up:same text" }, queue_texts(h))
    end)
end)
