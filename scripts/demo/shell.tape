Require btop
Require fish
Require nvim

Output "/tmp/agent-workbench-vhs/shell.gif"
Output "/tmp/agent-workbench-vhs/shell.mp4"

Set Shell bash
Set Width 1440
Set Height 760
Set FontSize 14
Set Padding 0
Set Margin 0
Set Framerate 30
Set TypingSpeed 30ms
Set CursorBlink false

Hide
Type "cd /tmp/agent-workbench-vhs/workspace/workspace-alpha && AGENT_WORKBENCH_DEMO=shell nvim -i NONE"
Enter
Sleep 1s
Type ":Pi"
Enter
Wait+Screen /Hi! Ask me anything/
Show
Sleep 1s

Type "i!!"
Enter
Sleep 1s
Type `set -g DEMO_WORKBENCH ready; printf '\e[32mpersistent shell ready\e[0m\n'`
Enter
Wait+Screen /persistent shell ready/
Sleep 1s
Type `echo "state: $DEMO_WORKBENCH"`
Enter
Wait+Screen /state: ready/
Sleep 1s

Type "btop"
Enter
Wait+Screen /preset/
Sleep 3s
Type "q"
Wait+Screen /state: ready/
Sleep 2s
