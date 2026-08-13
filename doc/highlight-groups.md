# Highlight groups

All highlight groups are defined with `default = true`, so they can be overridden by your colorscheme or by a later `vim.api.nvim_set_hl` call. Most groups are computed from your base colorscheme at load time (pulling from `Normal`, `Title`, `Function`, `Special`, `Comment`, `WarningMsg`, `DiagnosticError`, `DiagnosticWarn`, `DiagnosticOk`, `CursorLine`, and the diff/gitsigns groups), rather than linking directly to another group. Definitions are (re)applied on `ColorScheme` and `VimEnter`, so switching themes keeps π colors in sync. Run `:hi PiGroupName` at any time to see the current value.

## Chat history

| Group | Role |
| --- | --- |
| `PiUserMessageLabel` | Inline label in front of a user message |
| `PiUserBody` | Body text of user messages |
| `PiAgentResponseLabel` | Inline label in front of an agent response |
| `PiDebugLabel` | Inline label for debug entries |
| `PiStartupLabel` | Inline label for the startup block |
| `PiStartupHint` | Hint text inside the startup block |
| `PiStartupDetail` | Detail lines inside the startup block |
| `PiStartupError` | Error lines inside the startup block |
| `PiSystemErrorIcon` | Icon for system-error entries in the history |
| `PiErrorRail` | Vertical rail drawn alongside hard-wrapped error lines |
| `PiCompactionLabel` | Icon label for compaction summaries |
| `PiCompactionText` | Body text inside compaction summaries |
| `PiCompactionHint` | Expand/collapse hint inside collapsed compaction summaries |
| `PiMessageDateTime` | Timestamp next to messages |
| `PiMessageQueueTag` | Queue tag (steer / follow-up) next to queued messages |
| `PiMessageAttachments` | Attachment summary under a message |
| `PiPendingQueueLabel` | Label/icon for pending queued messages (history preview rows and statusline `queue` count) |
| `PiPendingQueueText` | Text of pending queued messages |
| `PiThinking` | Thinking block header label (and expanded body) |
| `PiThinkingPreview` | Thinking content preview on the collapsed single-line header (subdued, italic) |
| `PiMention` | Highlighted `@mention` in the prompt and history |
| `PiCommand` | Highlighted `/command` on the first line of the prompt |
| `PiWelcome` | Welcome text on an empty chat |
| `PiWelcomeHint` | Hint text under the welcome |
| `PiBusy` | "Agent is working" status text |
| `PiBusyTime` | Elapsed time counter next to the busy status |
| `PiAbortHint` | "Press <Esc> again to abort" hint in the statusline center |
| `PiAborted` | Transient "Aborted" confirmation in the statusline center + in-history abort marker |
| `PiWarning` | Inline warning lines |
| `PiError` | Inline error lines |
| `PiDebug` | Inline debug lines |

## Direct bash blocks

| Group | Role |
| --- | --- |
| `PiBashHeader` | Header row of a direct bash (`!`) block |
| `PiBashOutput` | Output body of a direct bash block |

## Tool blocks

| Group | Role |
| --- | --- |
| `PiToolBorder` | Tool block indent / fold glyphs |
| `PiToolBody` | Shared background painting a tool / bash block as one continuous container (header → footer) |
| `PiToolRunning` | Spinner on a running tool's header row |
| `PiToolHeader` | Tool block header row (tool name) |
| `PiToolCall` | Tool input / call summary (main body level, normal text color) |
| `PiToolOutput` | Tool output body (receded, italic) |
| `PiToolStatus` | Tool status line (completed / rejected / aborted) |
| `PiToolInlineDone` | Status text of a finished inline tool (e.g. `read`) |
| `PiToolCollapsed` | `+N lines` / `…N lines` markers on collapsed blocks |
| `PiToolError` | Tool error output |
| `PiTableBorder` | Table border inside tool output |
| `PiTableHeader` | Table header row inside tool output |
| `PiDiffAdd` | Added lines inside inline tool diffs (links to `DiffAdd`) |
| `PiDiffDelete` | Removed lines inside inline tool diffs (links to `DiffDelete`) |
| `PiDiffLineNr` | Line numbers inside inline tool diffs |
| `PiDiffAddSign` | The `+` sign on added diff lines (semantic color from `DiffAdd`) |
| `PiDiffDeleteSign` | The `-` sign on removed diff lines (semantic color from `DiffDelete`) |

## Attachments

| Group | Role |
| --- | --- |
| `PiAttachmentIcon` | Icon prefix in the attachments buffer |
| `PiAttachmentFilename` | Filename text in the attachments buffer |
| `PiAttachmentSize` | File size suffix in the attachments buffer (links to `Comment`) |

## Panels and layout

| Group | Role |
| --- | --- |
| `PiFloat` | `NormalFloat` for π float windows |
| `PiFloatBorder` | Border for π float windows |
| `PiChatHistoryWinbar` | Winbar background for the history panel (side layout) |
| `PiChatHistoryWinbarTitle` | Winbar title for the history panel (side layout) |
| `PiChatPromptWinbar` | Winbar background for the prompt panel (side layout) |
| `PiChatPromptWinbarTitle` | Winbar title for the prompt panel (side layout) |
| `PiChatPromptWinbarAttentionTitle` | Winbar title for the prompt panel when attention is pending |
| `PiChatPromptWinbarBashTitle` | Winbar title for the prompt panel in direct bash mode |
| `PiChatAttachmentsWinbar` | Winbar background for the attachments panel (side layout) |
| `PiChatAttachmentsWinbarTitle` | Winbar title for the attachments panel (side layout) |
| `PiChatHistoryFloatTitle` | Float title for the history panel (float layout) |
| `PiChatPromptFloatTitle` | Float title for the prompt panel (float layout) |
| `PiChatPromptFloatAttentionTitle` | Float title for the prompt panel when attention is pending |
| `PiChatPromptFloatBashTitle` | Float title for the prompt panel in direct bash mode |
| `PiPromptRequestTitle` | Title inside prompt request mode |
| `PiPromptRequestSelected` | Selected option inside prompt request mode |
| `PiChatAttachmentsFloatTitle` | Float title for the attachments panel (float layout) |

## Zen mode

| Group | Role |
| --- | --- |
| `PiZen` | Background of the centered zen prompt window |
| `PiZenBackdrop` | Background of the dimmed zen backdrop |

## Dialogs

| Group | Role |
| --- | --- |
| `PiDialogTitle` | Dialog title bar |

## Diff review

| Group | Role |
| --- | --- |
| `PiDiffWinbar` | Winbar background for the diff review tab |
| `PiDiffWinbarCurrent` | `CURRENT:` label on the left pane winbar |
| `PiDiffWinbarProposed` | `PROPOSED:` label on the right pane winbar |
| `PiDiffWinbarHint` | Key hint text (`[<Leader>da=accept ...]`) on the winbar |
| `PiDiffReviewNote` | Sign and virtual text for line-level diff review notes |
| `PiDiffReviewFile` | File header in the `:PiDiff` float; `M` status letter in the `:PiDiff` file list |
| `PiDiffReviewHint` | Hint line (file count / key hints) in the `:PiDiff` file list |
| `PiDiffReviewFloatTitle` | Float title of the `:PiDiff` window |
| `PiDiffAddSign` / `PiDiffDeleteSign` | `A` / `D` status letters in the `:PiDiff` file list (same groups as inline diff signs) |

## Statusline

| Group | Role |
| --- | --- |
| `PiStatusLine` | Default highlight for statusline chunks |
| `PiStatusLineAttention` | Attention component highlight |
| `PiStatusLineWarning` | `warn`-threshold highlight for `context` / `cost` components |
| `PiStatusLineError` | `error`-threshold highlight for `context` / `cost` components |

## Session stats

| Group | Role |
| --- | --- |
| `PiStatsBar` | Bar fill in the `:PiSessionStats` dashboard (per-model cost bars and the context bar below its warn threshold) |

The dashboard reuses `PiToolHeader` for its section headers, `Comment` for dimmed labels, and `PiStatusLineWarning` / `PiStatusLineError` for the context bar above the warn/error thresholds.

## Sessions overview

| Group | Role |
| --- | --- |
| `PiSessionsListBusy` | Status dot while the agent is working (blinking yellow) |
| `PiSessionsListCompacting` | Status dot while the session is compacting |
| `PiSessionsListPending` | Status dot when the session needs attention |
| `PiSessionsListDone` | Status dot when a turn finished while you were elsewhere (blinking green) |
| `PiSessionsListError` | Status dot when the last turn errored / the process died (blinking red) |
| `PiSessionsListExited` | Status dot for a dead process (steady error color) |
| `PiSessionsListIdle` | Status dot for an idle session |
| `PiSessionsListDotDim` | Dim phase of blinking dots |
| `PiSessionsListCurrent` | Marks the current tab's own session dot in the agent color |
| `PiSessionsListFloatTitle` | Float title for the sessions list window |
