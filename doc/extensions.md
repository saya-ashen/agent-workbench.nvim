# Extensions & custom rendering

pi extensions are small TypeScript (or Node-compatible) modules that the backend loads at session start. They can intercept tool calls, register slash commands, expose keybindings, surface UI to the user, and inject arbitrary content into the chat. The permission extension in [Diff review](diff-review.md) is one example; the `rules:load` / progressive-disclosure hooks in [agentic-af](https://github.com/alex35mil/agentic-af) are others.

Agent Workbench is extension-aware. When pi runs under `--mode rpc`, extensions can address the client (Agent Workbench) via the [extension UI protocol](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md#extension-ui-protocol), and Agent Workbench routes each method to the right surface in your editor:

| Extension UI method | Where Agent Workbench surfaces it |
| --- | --- |
| `notify` | `vim.notify` via the configured notify dispatcher |
| `setStatus` | `state.extensions[key]` in the statusline state (readable by custom [statusline](usage.md#statusline) components) |
| `setWidget` with key ending in `:startup` | [Startup block](#extension-startup-announcements) announcement |
| `setWidget` with any other key | Your `on_widget` config hook (see below) |
| `select` | Dialog or [diff review](diff-review.md), depending on the payload |
| `confirm` | Confirmation dialog |
| `input` / `editor` | Input dialog |
| `setTitle`, `set_editor_text` | Currently ignored (warned once) |

Dialog-style methods (`select`, `confirm`, `input`, `editor`) flow through the [Attention & dialogs](attention.md) queue described above. This page focuses on the pieces that aren't covered there: startup announcements, `on_widget`, and adapting non-upstream RPC backends.

## Extension startup announcements

Extensions can add their own sections to the [startup block](usage.md#startup-block) by calling `ctx.ui.setWidget` with a **widget key ending in `:startup`**. Agent Workbench routes those widgets into the startup block instead of rendering them inline, and the `:startup` suffix is stripped from the key for display.

For example, an extension calling:

```ts
ctx.ui.setWidget("permission:startup", [
    "defaultMode: ask",
    "allow: read, bash(git *)",
    "deny:  bash(rm -rf *)",
])
```

renders in the startup block as:

```
[Extension: permission]
  defaultMode: ask
  allow: read, bash(git *)
  deny:  bash(rm -rf *)
```

This is the intended surface for extensions that want to show session-relevant state the user should see up-front (current mode, loaded rules, active hooks, etc.) without cluttering the conversation itself.

Note the distinction from regular widgets: `setWidget` calls with keys that **don't** end in `:startup` are passed to your `on_widget` config hook instead and can be rendered inline in the history — the next section.

## Inline custom blocks via `on_widget`

> [!NOTE]
> Conceptually, this is a hack. `setWidget` was designed in the upstream pi protocol as a way for extensions to surface UI widgets in the TUI, not as a general extension ↔ Agent Workbench communication channel. Agent Workbench piggybacks on it because it's currently the **best handle pi provides** for an extension to push arbitrary data into the client. If/when pi gets a dedicated extension-to-client message type, this mechanism will likely be revisited. For now, treat `on_widget` as the escape hatch where "extension wants to say something to Agent Workbench" becomes possible at all.

When an extension calls `ctx.ui.setWidget(key, lines)` with a key that **doesn't** end in `:startup`, Agent Workbench passes it to your `on_widget` config function. The hook gets a chance to return a **custom block** that Agent Workbench will render inline in the history — right at the point in the conversation where the extension fired.

The signature:

```lua
---@param key string            -- the widgetKey the extension sent
---@param lines string[]|nil    -- widgetLines (nil when the extension cleared the widget)
---@param placement string|nil  -- "aboveEditor" / "belowEditor" (as sent by the extension)
---@return agent_workbench.CustomBlock|nil
function(key, lines, placement)
    -- return a block, or nil to ignore this widget
end
```

Return `nil` to ignore a widget and let it vanish quietly. Return an `agent_workbench.CustomBlock` to render it inline:

```lua
---@class agent_workbench.CustomBlock
---@field target  "history"          -- only "history" is supported today
---@field block   "custom"           -- discriminator; always "custom"
---@field content agent_workbench.CustomBlockLine[]
```

An `agent_workbench.CustomBlockLine` is a list of styled chunks, and each chunk is a `{ text, hl_group? }` pair:

```lua
-- One line, two chunks with different highlights:
{
    { "    ╰  rule: ", "Comment" },
    { ".agents/rules/ts.md", "AgentWorkbenchMention" },
}
```

### Example

Let's walk through a concrete case. My [rules extension](https://github.com/alex35mil/agentic-af/tree/main/extensions/rules) discovers Markdown rule files under `~/.pi/agent/rules/` (global) and `<repo>/.agents/rules/` (project). Some rules are always-on — their bodies are injected into the system prompt on every turn. Others are **path-scoped**: they have a `paths:` glob list in the frontmatter and are only delivered when the agent reads a file that matches one of those globs. In that case the extension appends the rule body to the `read` tool result (so the agent sees it) _and_ fires a `setWidget("rules:load", [...rule paths])` so **you** can see, inline in the chat, which rules just got loaded for which file.

Without `on_widget`, that widget would simply be ignored by Agent Workbench. With `on_widget`, it becomes a small annotation attached to the read tool call, telling you exactly which rules the agent now has in its context for the file it just read. It's the difference between trusting that the rules extension is doing its job and being able to _see_ it do its job.

Here's the hook that turns that widget into an inline annotation:

```lua
require("agent-workbench").setup({
    on_widget = function(key, lines)
        if key == "rules:load" and lines then
            local content = {}
            for _, line in ipairs(lines) do
                content[#content + 1] = {
                    { "   ╰  rule: " .. line, "Comment" },
                }
            end
            return {
                target = "history",
                block = "custom",
                content = content,
            }
        end
        return nil
    end,
})
```

On the extension side, the rules extension watches tool calls (`read`, `edit`, `write`, etc.) and, when it matches a file against one of its rule definitions, fires a widget listing the **paths of the rule files** that apply:

```ts
ctx.ui.setWidget("rules:load", [
    ".agents/rules/lua.md",
    ".agents/rules/neovim.md",
])
```

Agent Workbench calls your `on_widget`, sees the returned block, and writes it into the history buffer at the current insertion point — so the list appears directly underneath the tool call that triggered it, making it obvious which rules the agent should have loaded for that particular file.

The payload the extension sends is deliberately minimal (just rule file paths); turning that into a nicely-formatted inline block — prefix, icon, highlight — is entirely the job of `on_widget` on the Neovim side. Different users can present the same widget data however they want without the extension having to know anything about styling.

### Limitations

Same upstream constraint as the [startup block](usage.md#startup-block): `setWidget` in RPC mode only carries string arrays. Styling and structure are added _in Agent Workbench_ by your `on_widget` hook — the extension can't pre-style the output. Give `on_widget` everything it needs to make decisions (the `key` namespaces widgets from different extensions, and `lines` carries the payload) and do the formatting there.

## Adapting non-upstream RPC backends

Agent Workbench targets upstream pi RPC. If you point `cli.bin` at a fork with a different protocol, use `rpc.map_command` / `rpc.map_event` to translate in user config instead of patching Agent Workbench core.

Both hooks receive the message plus a context table and return the mapped message, or `nil` to drop it. The context currently exposes `ctx.set_commands(commands)`, which replaces Agent Workbench's shared slash-command cache (the same cache populated by upstream `get_commands` responses — it feeds completion, prompt decorators, and command-aware chat behavior; it does not re-render the already-visible startup block).

<details>
<summary>Example: adapt `omp` command-list compatibility</summary>

```lua
local function normalize_omp_commands(commands)
    local result = {}
    for _, command in ipairs(commands or {}) do
        local cmd = vim.deepcopy(command)
        if cmd.source == "file" or cmd.source == "custom" or cmd.source == "mcp_prompt" then
            cmd.source = "prompt"
        elseif cmd.source == "builtin" then
            cmd.source = "extension"
        end
        result[#result + 1] = cmd
    end
    return result
end

local function strip_ansi(text)
    return text:gsub("\27%[[0-9;]*m", "")
end

require("agent-workbench").setup({
    cli = { bin = "omp" },
    rpc = {
        map_command = function(cmd)
            if cmd.type == "get_commands" then
                local mapped = vim.deepcopy(cmd)
                mapped.type = "get_available_commands"
                return mapped
            end
            return cmd
        end,
        map_event = function(msg, ctx)
            if msg.type == "command_output" then
                local text = strip_ansi(msg.text or "")
                if text ~= "" then
                    vim.schedule(function()
                        require("agent-workbench.notify").info(text)
                    end)
                end
                return nil
            end
            if msg.type == "ready" then
                return nil
            end
            if msg.type == "response" and msg.command == "get_available_commands" then
                local mapped = vim.deepcopy(msg)
                mapped.command = "get_commands"
                if mapped.data then
                    mapped.data.commands = normalize_omp_commands(mapped.data.commands)
                end
                return mapped
            end
            if msg.type == "available_commands_update" then
                ctx.set_commands(normalize_omp_commands(msg.commands))
                return nil
            end
            return msg
        end,
    },
})
```

</details>
