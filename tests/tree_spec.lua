-- Unit tests for pi.tree (session tree navigation). Pure logic only: entry
-- classification, text extraction, tree flattening, command building, and
-- picker formatting. No RPC, no UI.

describe("pi.tree", function()
    local Tree = require("pi.tree")

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
            assert.are.equal("hello", Tree.entry_preview(msg("a", "user", "hello")))
        end)

        it("concatenates text parts of array content", function()
            local e = msg("a", "user", {
                { type = "text", text = "hello " },
                { type = "image" },
                { type = "text", text = "world" },
            })
            assert.are.equal("hello world", Tree.entry_preview(e))
        end)

        it("collapses whitespace to a single line", function()
            assert.are.equal("a b c", Tree.entry_preview(msg("a", "user", "a\n  b\tc")))
        end)

        it("uses summary text for summaries and compaction", function()
            assert.are.equal("sum", Tree.entry_preview({ type = "branch_summary", summary = "sum" }))
            assert.are.equal("cmp", Tree.entry_preview({ type = "compaction", summary = "cmp" }))
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
        it("flattens DFS with visible depth and leaf marking", function()
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
            -- toolResult is hidden: 3 visible items, and it does not add visible depth
            assert.are.equal(3, #items)
            assert.are.same({ "u1", "a1", "a2" }, { items[1].id, items[2].id, items[3].id })
            assert.are.same({ 0, 1, 2 }, { items[1].depth, items[2].depth, items[3].depth })
            assert.is_false(items[1].is_leaf)
            assert.is_true(items[3].is_leaf)
            assert.are.equal("first", items[1].editor_text)
            assert.is_nil(items[2].editor_text)
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
        it("renders indent, kind, text, leaf marker and label", function()
            local s = Tree.format_item({
                id = "x",
                depth = 2,
                kind = "user",
                text = "hello",
                label = "branch",
                is_leaf = true,
            })
            assert.are.equal("    ● [user] hello  ⚑ branch", s)
        end)

        it("renders a placeholder for empty text", function()
            local s = Tree.format_item({ id = "x", depth = 0, kind = "compaction", text = "", is_leaf = false })
            assert.are.equal("  [compaction] (no text)", s)
        end)
    end)
end)
