vim.deprecate(":checkhealth pi", ":checkhealth agent-workbench", "2.0.0", "Agent Workbench", false)

return require("agent-workbench.health")
