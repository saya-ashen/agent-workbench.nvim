local Compiler = require("agent-workbench.ui.markdown.compiler")

local function has(plan, predicate)
    for _, decoration in ipairs(plan.decorations) do
        if predicate(decoration) then
            return true
        end
    end
    return false
end

describe("isolated Markdown compiler", function()
    local original_parser

    before_each(function()
        original_parser = package.loaded["markview.parser"]
        Compiler._reset()
    end)

    after_each(function()
        package.loaded["markview.parser"] = original_parser
        Compiler._reset()
    end)

    it("renders the supported Markview semantic node set into a local plan", function()
        package.loaded["markview.parser"] = {
            init = function()
                return {
                    markdown = {
                        {
                            class = "markdown_atx_heading",
                            marker = "#",
                            range = { row_start = 0, col_start = 0, row_end = 1, col_end = 0 },
                        },
                        {
                            class = "markdown_block_quote",
                            range = { row_start = 1, col_start = 0, row_end = 2, col_end = 0 },
                        },
                        {
                            class = "markdown_list_item",
                            marker = "-",
                            range = { row_start = 2, col_start = 0, row_end = 3, col_end = 0 },
                        },
                        {
                            class = "markdown_checkbox",
                            state = "x",
                            range = { row_start = 2, col_start = 2, row_end = 2, col_end = 5 },
                        },
                        {
                            class = "markdown_code_block",
                            language = "lua",
                            range = {
                                row_start = 3,
                                col_start = 0,
                                row_end = 6,
                                col_end = 0,
                                start_delim = { 3, 0, 3, 3 },
                            },
                        },
                        {
                            class = "markdown_table",
                            alignments = { "default", "default" },
                            range = { row_start = 6, col_start = 0, row_end = 9, col_end = 0 },
                        },
                        {
                            class = "markdown_hr",
                            range = { row_start = 9, col_start = 0, row_end = 10, col_end = 0 },
                        },
                        {
                            class = "markdown_unknown_extension",
                            range = { row_start = 10, col_start = 0, row_end = 11, col_end = 0 },
                        },
                    },
                    markdown_inline = {
                        {
                            class = "inline_link_hyperlink",
                            range = { row_start = 10, col_start = 0, row_end = 10, col_end = 11 },
                        },
                    },
                }, {}
            end,
        }
        local source = table.concat({
            "# Heading",
            "> quote",
            "- [x] task",
            "```lua",
            "local x = 1",
            "```",
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
            "---",
            "[link](url)",
        }, "\n")
        local plan, err = Compiler.compile(source, {
            width = 20,
            features = {},
            symbols = {
                bullet = "•",
                checked = "yes",
                block_quote = "│",
                link = "link ",
                horizontal_rule = "-",
            },
        })
        assert.is_nil(err)
        assert.is_not_nil(plan)
        assert.is_true(plan.width_dependent)
        assert.is_true(has(plan, function(decoration)
            return decoration.hl_group == "AgentWorkbenchMarkdownHeading1"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.line_hl_group == "AgentWorkbenchMarkdownBlockQuote"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.virt_text and decoration.virt_text[1][1] == "•"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.virt_text and decoration.virt_text[1][1] == "yes"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.line_hl_group == "AgentWorkbenchMarkdownCodeBlock"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.hl_group == "@keyword.lua"
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.virt_lines ~= nil
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.virt_text
                and decoration.virt_text[1][1] == string.rep("-", 20)
                and decoration.hl_group == nil
        end))
        assert.is_true(has(plan, function(decoration)
            return decoration.virt_text and decoration.virt_text[1][1] == "link "
        end))
    end)

    it("honors feature switches for Tree-sitter highlights and conceal", function()
        package.loaded["markview.parser"] = {
            init = function()
                return { markdown = {}, markdown_inline = {} }, {}
            end,
        }
        local plan = assert(Compiler.compile("**bold** [link](url) `code`", {
            width = 80,
            features = { emphasis = false, links = false, inline_code = false },
            symbols = {},
        }))
        assert.is_false(has(plan, function(decoration)
            return decoration.hl_group == "AgentWorkbenchMarkdownStrong"
                or decoration.hl_group == "AgentWorkbenchMarkdownLink"
                or decoration.hl_group == "AgentWorkbenchMarkdownInlineCode"
        end))
        assert.is_false(has(plan, function(decoration)
            return decoration.conceal ~= nil
        end))
    end)

    it("maps fenced-language captures without depending on Markview code ranges", function()
        package.loaded["markview.parser"] = {
            init = function()
                return { markdown = {}, markdown_inline = {} }, {}
            end,
        }
        local plan, err = Compiler.compile("````lua\nlocal value = 1\n````", {
            width = 80,
            features = {},
            symbols = {},
        })
        assert.is_nil(err)
        assert.is_true(has(plan, function(decoration)
            return decoration.hl_group == "@keyword.lua" and decoration.row == 1
        end))
    end)

    it("turns parser exceptions and incompatible results into compile errors", function()
        package.loaded["markview.parser"] = {
            init = function()
                error("parse boom")
            end,
        }
        local thrown_plan, thrown_error = Compiler.compile("# raw", { width = 80, features = {}, symbols = {} })
        assert.is_nil(thrown_plan)
        assert.is_not_nil(thrown_error:find("parse boom", 1, true))

        package.loaded["markview.parser"] = {
            init = function()
                return {}, nil
            end,
        }
        local invalid_plan, invalid_error = Compiler.compile("# raw", { width = 80, features = {}, symbols = {} })
        assert.is_nil(invalid_plan)
        assert.is_not_nil(invalid_error:find("incompatible", 1, true))
    end)

    it("returns a compatibility error instead of mutating output", function()
        package.loaded["markview.parser"] = { init = false }
        local plan, err = Compiler.compile("# raw", { width = 80, features = {}, symbols = {} })
        assert.is_nil(plan)
        assert.is_not_nil(err)
        assert.is_not_nil(err:find("unavailable", 1, true))
    end)
end)
