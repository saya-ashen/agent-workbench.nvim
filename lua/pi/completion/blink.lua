vim.deprecate(
    "module = 'pi.completion.blink'",
    "module = 'agent-workbench.completion.blink'",
    "2.0.0",
    "Agent Workbench",
    false
)

return require("agent-workbench.completion.blink")
