Require nvim

Output "/tmp/agent-workbench-vhs/overview.gif"
Output "/tmp/agent-workbench-vhs/overview.mp4"

Set Shell bash
Set Width 1440
Set Height 760
Set FontSize 14
Set Padding 0
Set Margin 0
Set Framerate 30
Set TypingSpeed 35ms
Set CursorBlink false

Hide
Type "cd /tmp/agent-workbench-vhs/workspace/workspace-alpha && AGENT_WORKBENCH_DEMO=overview nvim -i NONE"
Enter
Sleep 1s
Type ":Pi"
Enter
Wait+Screen /Hi! Ask me anything/
Show
Sleep 1s

Type "i"
Type "Review workspace status and suggest next steps"
Enter
Wait+Screen /Buffer chat keeps this conversation/
Sleep 2s

Escape
Type ":PiNewSession"
Enter
Wait+Screen /Hi! Ask me anything/
Type "i"
Type "Check test coverage in a separate session"
Enter
Sleep 1s

Escape
Type ":PiSessions"
Enter
Wait+Screen /Test coverage/
Sleep 2s
Sleep 4s
Wait+Screen /Test coverage/
Sleep 1s
Type "q"

Type ":PiNewWorkspace"
Enter
Wait+Screen /Workspace path:/
Ctrl+U
Type "/tmp/agent-workbench-vhs/workspace/workspace-beta"
Enter
Sleep 2s
Wait+Screen /Hi! Ask me anything/
Type "i"
Type "Review this workspace in isolation"
Enter
Wait+Screen /Workspace beta has its own session/
Sleep 2s

Escape
Type "gT"
Sleep 2s
Type ":PiWorkspaces"
Enter
Wait+Screen /Select workspace/
Sleep 2s
Enter
Wait+Screen /Test coverage is still working/
Sleep 1s
