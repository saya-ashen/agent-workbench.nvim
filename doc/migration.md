# Migration

Agent Workbench is independently maintained. Current releases use `agent-workbench` as canonical public namespace and keep `pi` compatibility during migration.

## New setup

Use the Agent Workbench repository and namespace:

```lua
require("agent-workbench").setup()
```

Use canonical commands such as `:AgentWorkbench`, `:AgentWorkbenchContinue`, and `:AgentWorkbenchToggleLayout`.

For blink.cmp, use:

```lua
require("agent-workbench.completion.blink")
```

## Existing setup

These old entry points remain available until `2.0.0`:

- `require("pi")`
- `:Pi*` commands, when another plugin has not already registered the name
- `pi.completion.blink`
- `pi-chat-*` filetypes and `Pi*` highlight groups

Old configuration can keep working while you migrate. New configuration should use the canonical namespace and command family.

## Mixed installations

Do not install Agent Workbench and the original `pi.nvim` in the same runtimepath unless necessary. Both provide `lua/pi/` compatibility modules, so `require("pi")` and `pi.completion.blink` resolve according to runtimepath order. Use `require("agent-workbench")` and `agent-workbench.completion.blink` to select Agent Workbench explicitly.

`:Pi*` aliases are guarded: Agent Workbench does not replace a command already owned by another plugin. Canonical `:AgentWorkbench*` commands avoid that command-name collision.

## Upgrade steps

1. Change the plugin repository to `saya-ashen/agent-workbench.nvim`.
2. Change `require("pi")` to `require("agent-workbench")`.
3. Change `pi.completion.blink` to `agent-workbench.completion.blink`.
4. Change custom `:Pi*` mappings to `:AgentWorkbench*` commands.
5. Restart Neovim after changing the namespace. Existing `package.loaded` modules stay in memory for the current process.

Compatibility aliases will be removed in `2.0.0`. Filetypes and highlight groups remain stable for now; migrate those only when a future major release documents their replacement.
