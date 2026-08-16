-- Unit tests for pi.tree (session tree navigation). Pure logic only: entry
-- classification, text extraction, tree flattening, command building, and
-- picker formatting. No RPC, no UI.

describe("pi.tree", function()
    local Tree = require("agent-workbench.tree")

    local function msg(id, role, content, parent)
        return {
            type = "message",
            id = id,
            parentId = parent,
            message = { role = role, content = content },
        }
    end

    describe("entry_kind", function()
        it("maps user and assistant messages", function()
            assert.are.equal("user", Tree.entry_kind(msg("a", "user", "hi")))
            assert.are.equal("assistant", Tree.entry_kind(msg("b", "assistant", "hi")))
        end)

        it("hides toolResult messages", function()
            assert.is_nil(Tree.entry_kind(msg("t", "toolResult", {})))
        end)

        it("maps custom_message, branch_summary, compaction", function()
            assert.are.equal("custom", Tree.entry_kind({ type = "custom_message", content = "x" }))
            assert.are.equal("summary", Tree.entry_kind({ type = "branch_summary", summary = "x" }))
            assert.are.equal("compaction", Tree.entry_kind({ type = "compaction", summary = "x" }))
        end)

        it("hides noise entries", function()
            assert.is_nil(Tree.entry_kind({ type = "thinking_level_change" }))
            assert.is_nil(Tree.entry_kind({ type = "model_change" }))
            assert.is_nil(Tree.entry_kind({ type = "label" }))
            assert.is_nil(Tree.entry_kind({ type = "session_info" }))
            assert.is_nil(Tree.entry_kind({ type = "custom" }))
        end)
    end)

    describe("entry_preview", function()
        it("extracts text from string content", function()
            local text, kind = Tree.entry_preview(msg("a", "user", "hello"))
            assert.are.equal("hello", text)
            assert.are.equal("text", kind)
        end)

        it("concatenates text parts of array content", function()
            local e = msg("a", "user", {
                { type = "text", text = "hello " },
                { type = "image" },
                { type = "text", text = "world" },
            })
            local text, kind = Tree.entry_preview(e)
            assert.are.equal("hello world", text)
            assert.are.equal("text", kind)
        end)

        it("collapses whitespace to a single line", function()
            local text = Tree.entry_preview(msg("a", "user", "a\n  b\tc"))
            assert.are.equal("a b c", text)
        end)

        it("uses summary text for summaries and compaction", function()
            assert.are.equal("sum", Tree.entry_preview({ type = "branch_summary", summary = "sum" }))
            assert.are.equal("cmp", Tree.entry_preview({ type = "compaction", summary = "cmp" }))
        end)

        it("summarizes a tool-only assistant turn with a first-arg fragment", function()
            local e = msg("a", "assistant", {
                { type = "toolCall", name = "bash", arguments = { command = "cd ~/x && ls -la\nsecond line" } },
            })
            local text, kind = Tree.entry_preview(e)
            assert.are.equal("tools", kind)
            assert.are.not_equal("", text)
            -- first line of the command only, never the old placeholder
            assert.is_truthy(text:find("cd ~/x && ls -la", 1, true))
            assert.is_nil(text:find("second line", 1, true))
            assert.is_nil(text:find("(no text)", 1, true))
        end)

        it("lists two tools and folds the rest with (+N)", function()
            local e = msg("a", "assistant", {
                { type = "toolCall", name = "bash", arguments = { command = "one" } },
                { type = "toolCall", name = "edit", arguments = { path = "/lua/agent-workbench/tree.lua" } },
                { type = "toolCall", name = "read", arguments = { path = "/lua/agent-workbench/rpc.lua" } },
            })
            local text, kind = Tree.entry_preview(e)
            assert.are.equal("tools", kind)
            assert.is_truthy(text:find("(+1)", 1, true))
        end)

        it("marks an aborted turn", function()
            local e = {
                type = "message",
                id = "a",
                message = { role = "assistant", content = {}, stopReason = "aborted" },
            }
            local text, kind = Tree.entry_preview(e)
            assert.are.equal("(aborted)", text)
            assert.are.equal("status", kind)
        end)

        it("marks an errored turn with its message", function()
            local e = {
                type = "message",
                id = "a",
                message = {
                    role = "assistant",
                    content = {},
                    stopReason = "error",
                    errorMessage = "The operation timed out.",
                },
            }
            local text, kind = Tree.entry_preview(e)
            assert.are.equal("(error: The operation timed out.)", text)
            assert.are.equal("status", kind)
        end)

        it("falls back to (empty) for a text-less turn with no tools or status", function()
            local text, kind = Tree.entry_preview(msg("a", "assistant", {}))
            assert.are.equal("(empty)", text)
            assert.are.equal("empty", kind)
        end)
    end)

    describe("editor_text", function()
        it("returns full text for user messages", function()
            local e = msg("a", "user", { { type = "text", text = "edit me" } })
            assert.are.equal("edit me", Tree.editor_text(e))
        end)

        it("returns full text for custom messages", function()
            assert.are.equal("note", Tree.editor_text({ type = "custom_message", content = "note" }))
        end)

        it("returns nil for assistant messages and summaries", function()
            assert.is_nil(Tree.editor_text(msg("a", "assistant", "reply")))
            assert.is_nil(Tree.editor_text({ type = "branch_summary", summary = "s" }))
        end)

        it("returns nil for empty user text", function()
            assert.is_nil(Tree.editor_text(msg("a", "user", { { type = "image" } })))
        end)
    end)

    describe("flatten", function()
        it("keeps a linear conversation flat (depth counts forks, not length)", function()
            local tree = {
                {
                    entry = msg("u1", "user", "first"),
                    children = {
                        {
                            entry = msg("a1", "assistant", "reply"),
                            children = {
                                {
                                    entry = msg("t1", "toolResult", {}),
                                    children = {
                                        { entry = msg("a2", "assistant", "done"), children = {} },
                                    },
                                },
                            },
                        },
                    },
                },
            }
            local items = Tree.flatten(tree, "a2")
            -- toolResult is hidden: 3 visible items. Every node has a single
            -- child, so this is one linear conversation and stays flat at
            -- depth 0 — no per-message indentation marching off-screen.
            assert.are.equal(3, #items)
            assert.are.same({ "u1", "a1", "a2" }, { items[1].id, items[2].id, items[3].id })
            assert.are.same({ 0, 0, 0 }, { items[1].depth, items[2].depth, items[3].depth })
            assert.is_false(items[1].is_leaf)
            assert.is_true(items[3].is_leaf)
            assert.are.equal("first", items[1].editor_text)
            assert.is_nil(items[2].editor_text)
            -- text-bearing entries carry preview_kind = "text"
            assert.are.equal("text", items[1].preview_kind)
        end)

        it("indents genuine branches but not their linear continuations", function()
            -- u1 forks into two alternative assistant replies; the second one
            -- continues linearly with a follow-up user message.
            local tree = {
                {
                    entry = msg("u1", "user", "question"),
                    children = {
                        { entry = msg("a1", "assistant", "attempt 1"), children = {} },
                        {
                            entry = msg("a2", "assistant", "attempt 2"),
                            children = {
                                { entry = msg("u2", "user", "follow-up"), children = {} },
                            },
                        },
                    },
                },
            }
            local items = Tree.flatten(tree, "u2")
            assert.are.same({ "u1", "a1", "a2", "u2" }, { items[1].id, items[2].id, items[3].id, items[4].id })
            -- u1 is the root (0); its two children are a fork (1); u2 is the
            -- single-child continuation of a2, so it stays at 1, not 2.
            assert.are.same({ 0, 1, 1, 1 }, { items[1].depth, items[2].depth, items[3].depth, items[4].depth })
        end)

        it("flattens a tool-only entry with a non-empty tool summary", function()
            local tree = {
                {
                    entry = msg("u1", "user", "do it"),
                    children = {
                        {
                            entry = {
                                type = "message",
                                id = "a1",
                                message = {
                                    role = "assistant",
                                    content = {
                                        { type = "toolCall", name = "bash", arguments = { command = "ls" } },
                                    },
                                },
                            },
                            children = {},
                        },
                    },
                },
            }
            local items = Tree.flatten(tree, "a1")
            assert.are.equal(2, #items)
            assert.are.equal("tools", items[2].preview_kind)
            assert.are.not_equal("", items[2].text)
            assert.is_nil(items[2].text:find("(no text)", 1, true))
        end)

        it("keeps branch labels and handles multiple roots", function()
            local tree = {
                { entry = msg("r1", "user", "root one"), children = {}, label = "main" },
                { entry = msg("r2", "user", "orphan"), children = {} },
            }
            local items = Tree.flatten(tree, nil)
            assert.are.equal(2, #items)
            assert.are.equal("main", items[1].label)
            assert.is_nil(items[2].label)
        end)

        it("returns an empty list for an empty session", function()
            assert.are.same({}, Tree.flatten({}, nil))
        end)
    end)

    describe("build_command", function()
        it("builds none and summary modes", function()
            assert.are.equal("/tree abc none", Tree.build_command("abc", "none"))
            assert.are.equal("/tree abc summary", Tree.build_command("abc", "summary"))
        end)

        it("appends custom instructions verbatim", function()
            assert.are.equal(
                "/tree abc custom focus on the tests",
                Tree.build_command("abc", "custom", "focus on the tests")
            )
        end)

        it("falls back to plain custom when instructions are empty", function()
            assert.are.equal("/tree abc custom", Tree.build_command("abc", "custom", ""))
            assert.are.equal("/tree abc custom", Tree.build_command("abc", "custom", nil))
        end)
    end)

    describe("format_item", function()
        it("renders indent, leaf, kind, label then text", function()
            local s = Tree.format_item({
                id = "x",
                depth = 2,
                kind = "user",
                text = "hello",
                label = "branch",
                is_leaf = true,
            })
            -- label sits right after [kind], before the preview text
            assert.are.equal("    ● [user] ⚑ branch hello", s)
        end)

        it("renders an (empty) placeholder when text is missing", function()
            local s = Tree.format_item({ id = "x", depth = 0, kind = "compaction", text = "", is_leaf = false })
            assert.are.equal("  [compaction] (empty)", s)
        end)
    end)
end)
