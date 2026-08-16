# Sessions

π is session-oriented: every conversation is persisted to disk as it happens, you can leave one in the middle of a turn and pick it up later, and Agent Workbench gives you a few ways to navigate between them.

## Buffer-owned sessions

Agent Workbench binds each live session to its listed History buffer. One Neovim can keep multiple independent sessions in one tab or across tabs. Each session owns its History, prompt, attachments, model state, and `pi --mode rpc` subprocess.

Use normal buffer commands to switch sessions. Sessions start lazily by default: opening a workspace does not start `pi --mode rpc` until one of these chat/session commands runs.

```vim
:AgentWorkbench
:AgentWorkbenchNewSession
:AgentWorkbenchReplaceSession
:bnext
:bprevious
:buffer <session-history-buffer>
```

Entering a session History buffer switches the active chat view in the current tab, including prompt and attachments, while leaving focus on History in Normal mode. Press `i`, `I`, `a`, `A`, `o`, `O`, `c`, or `C` from History to focus the prompt and enter Insert mode. One session has at most one active view. Hiding or leaving a session buffer keeps its RPC process alive; background output continues in that session's own hidden History buffer and never replaces the active session view. `:bdelete` / `:bwipeout` on its History buffer stops that session and its RPC process. Closing a tab only detaches its view.

## Workspaces

Each Neovim tab acts as one workspace. On setup, Agent Workbench fixes current cwd as tab-local; new tabs inherit and fix their initial cwd. `:AgentWorkbenchNewWorkspace` opens a directory input with path completion, then creates a new tab rooted at the confirmed path. Cancellation or an invalid directory creates nothing. Use `:tcd {dir}` to change an existing workspace. If that workspace has an idle π session, Agent Workbench starts a fresh session whose RPC process, tools, resources, and persistence all use the new cwd, hands its visible History and prompt windows to the replacement, then stops the previous session and deletes its stale History buffer. A streaming, compacting, retrying, or direct-bash session blocks the change and restores its original cwd; wait or abort first. Files and later π sessions use the workspace cwd too. The workspace bar shows every tab, its cwd basename, live session count, and busy/attention marker. Click an item or use `gt` / `gT` to switch workspaces; `:AgentWorkbenchWorkspaces` opens a searchable picker.

When `bufferline.nvim` owns the tabline, Agent Workbench appends workspace tabs through bufferline's right custom area instead of replacing it. Workspace tabs show the short cwd basename by default, followed by session count and status; visible numeric indices are hidden while native click targets and `gt` / `gT` navigation remain active. Configure `workspace_bar.label = "path"` for full paths, `show_index = true` for visible indices, or pass a label function receiving the workspace row. While this integration is active, Agent Workbench disables bufferline's redundant native numeric tab indicators and restores their prior setting on reset. Workspace tabs preserve any existing right custom area. Other user-defined tablines are never overwritten. With no custom tabline, Agent Workbench installs its built-in workspace tabline temporarily and yields ownership if bufferline loads later.

`:AgentWorkbenchWorkspaceSidebar` toggles a collapsible workspace explorer (right side, 38 columns by default). Its compact tree-style rows show a shortened `~/...` cwd, then list that workspace's session History buffers and ordinary listed buffers together. Session rows show a backend title (falling back to `session <id>`), a state-specific icon, and a right-aligned `running`, `compacting`, `attention`, `idle`, or `stopped` state. Ordinary buffers show their basename, filetype icon and color from `nvim-web-devicons` when available, and a `modified` marker when changed; without devicons they use a generic file icon. On workspace rows, both `h` and `l` toggle expansion. On session rows, `h` collapses the parent workspace and `l` activates the session, focusing the prompt with History scrolled to latest output on first entry or restoring History at its last moved cursor afterward; on buffer rows, `<CR>` / `l` switches to the buffer. `e` / `<Tab>` also toggles workspace rows. `<CR>` switches the workspace or opens its selected item, `d` deletes an ordinary buffer directly or confirms before stopping a session and deleting its History buffer, `a` creates a session in the selected workspace, `A` opens the new-workspace path input, `o` switches and closes the sidebar, `R` refreshes workspaces and buffers, `?` toggles key help, and `q` closes. The sidebar is a native scratch buffer and split; it does not require Snacks or Neo-tree. Configure `workspace_sidebar.position` (`"left"` or `"right"`) and `workspace_sidebar.width`.

Buffers are tracked by workspace ownership. On tab switches, Agent Workbench temporarily lists only buffers owned by the current workspace, keeping bufferline, `:bnext`, and `:bprevious` scoped to that workspace without deleting hidden buffers. The workspace sidebar still groups tracked buffers from every workspace and keeps session History buffers with their creating workspace. A normal buffer can belong to multiple workspaces when entered there. Entering a session History buffer directly restores its last moved cursor and expanded/collapsed block folds, or opens at latest output when no cursor was recorded. `:AgentWorkbenchMoveBuffer {tab-number}` moves the current ordinary buffer to another workspace; π History buffers cannot be moved. Closing a workspace removes its membership only; it never deletes buffers or stops sessions.

```lua
require("agent-workbench").setup({
    workspace_bar = {
        enabled = true,
        show = "multiple", -- "multiple" | "always"
        label = "name", -- "name" | "path" | function(workspace) return string end
        show_index = false,
        session_count = true,
        status = true,
    },
    workspace_sidebar = {
        position = "right", -- "left" | "right"
        width = 38,
    },
    workspace_buffers = {
        enabled = true,
    },
})
```

## Session history as a buffer

Sessions are loaded in two phases: Agent Workbench first reads active-branch messages directly from JSONL, renders them without intermediate scrolling, and reveals the final message once. Prompt submissions stay blocked, with draft text preserved, until RPC `switch_session` and `get_messages` complete so preview text cannot be sent to the previous backend session. An identical authoritative response keeps the preview in place; only changed state triggers a rebuild. Late reload or startup callbacks update only their owning session and cannot retake the active History/prompt view. Unsupported or damaged files fall back to RPC-only loading.

The rendered agent transcript is a listed Neovim `nofile` buffer, not terminal output. Its stable virtual resource URI is tracked internally:

```text
agent://<project>/<session-id>/transcript
```

The URI starts as `agent://<project>/new-<id>/transcript` for a new session and changes to persisted session ID once RPC state provides its session file. Each URI owns its transcript buffer and History renderer state. The listed History buffer uses a readable `π session <session-id>` name for bufferline and file-tree plugins; if one session temporarily owns multiple transcript resources, later buffers add their buffer ID to keep Neovim names unique. Its `agent://...` URI remains in the buffer-local `pi_session_uri` field and workspace registry. `:edit agent://.../transcript` reuses an existing resource or activates its session in the current tab. History remains separate from prompt and attachment buffers. In buffer layout, opening a normal file replaces the current view and hides chat layout without stopping session; switching back to `π session <session-id>` buffer restores History and prompt.

## Storage and scoping

Sessions are JSONL documents stored under:

```text
<agent_dir>/sessions/<encoded-cwd>/*.jsonl
```

where `<agent_dir>` is resolved in this order:

1. `agent_dir` in `require("agent-workbench").setup(...)`
2. `$PI_CODING_AGENT_DIR` environment variable
3. `~/.pi/agent` (default)

Crucially, sessions are **scoped to the current working directory**. Sessions started in `~/Dev/project-a` are only visible to continue/resume when Agent Workbench is running from the same directory. This matches how you'd actually want it: you don't want to accidentally resume an unrelated project's conversation just because you opened a chat in a new tab.

## Starting, continuing, resuming

There are three ways to open a chat — each honors the usual `layout=side|float` override:

| Command | Lua | What it does |
| --- | --- | --- |
| `:AgentWorkbench` | `pi.show()` / `pi.toggle()` | Open the chat. If current tab has no active session, starts one. |
| `:AgentWorkbenchContinue` | `pi.continue_session()` | Load the most recent session not already live in another buffer. |
| `:AgentWorkbenchResume` | `pi.resume_session()` | Pick any past session. Selecting a live session activates its existing buffer. |

And mid-session management:

| Command | Lua | What it does |
| --- | --- | --- |
| `:AgentWorkbenchNewSession` | `pi.new_session()` | Create and activate a separate session buffer and RPC process. Existing sessions keep running. `/new` uses this behavior. |
| `:AgentWorkbenchReplaceSession` | `pi.replace_session()` | Create a fresh session in the current view, then stop the previous session and delete its live History buffer. `/replace` uses this behavior and refuses while the current session is busy. |
| `:AgentWorkbenchTree` | `pi.tree()` | Navigate the session tree: jump back to any past conversation point, optionally summarizing the abandoned branch. See [Session tree navigation](#session-tree-navigation-agentworkbenchtree). |
| `:AgentWorkbenchSessions` | `pi.sessions()` | Toggle the live overview of all active sessions (name + busy/idle/attention). See [Sessions overview](#sessions-overview-agentworkbenchsessions). |
| `:AgentWorkbenchSessionName [name]` | `pi.set_session_name(name?)` | Set a human-readable display name for the current session. Without an argument, opens an input dialog prefilled with the current name. Names appear in the `:AgentWorkbenchResume` picker so you can identify long-running conversations at a glance. |
| `:AgentWorkbenchStop` | `pi.stop()` | Tear down the current session entirely, killing the backing `pi --mode rpc` process. Different from `:AgentWorkbenchToggleChat`, which just hides the windows while the session keeps running. |

## Session tree navigation (:AgentWorkbenchTree)

A pi session is not a linear log but a **tree** of entries: going back to an earlier point and continuing from there creates a new branch, while the abandoned branch stays on disk. `:AgentWorkbenchTree` (or typing `/tree` in the prompt) is the π equivalent of the TUI's `/tree` command:

1. A picker lists the session's conversation entries (user/assistant messages, branch summaries, compactions), indented by *branch* depth — a linear conversation stays flat at the left edge (no per-message indent), only real forks nest — with `●` marking the current point and any branch label shown right after the entry's kind tag (before its preview text, so it survives truncation). Text-less assistant turns are never blank: a tool-only turn shows a compact tool-call summary (the chat's per-tool nerd-font icon as a lightweight marker, plus the first argument — the bash command, edited path, search pattern, …; extra tools on the same turn fold into `(+N)`), and an aborted or errored turn shows `(aborted)` / `(error: …)`. This mirrors the pi TUI's `/tree`, where every line carries content.
2. After picking an entry you're asked whether to **summarize the abandoned branch** — `No summary`, `Summarize`, or `Summarize with custom prompt` (mirrors the TUI; `Esc` backs out to the picker).
3. The backend moves the session leaf and the chat is rebuilt from the new branch. If you picked a user message, its text lands back in the prompt for editing and resending (the leaf moves to that message's *parent*).

Navigation is refused while the agent is streaming. Summarizing requires a selected model.

How it works: the RPC protocol has no `navigate_tree` command, so Agent Workbench bundles a tiny pi extension (`extensions/tree.ts`) and injects it into every RPC process via `--extension`. It registers a `/tree` command whose handler calls pi's `ctx.navigateTree()`; extension commands are awaited end-to-end over RPC, so the chat rebuilds exactly when navigation (and any summarization) completes.

```lua
require("agent-workbench").setup({
    tree = {
        enabled = true, -- set false to stop injecting the extension and disable :AgentWorkbenchTree
    },
})
```

Requires a pi version whose extension API exposes `ctx.navigateTree` — on older versions the command fails with an explicit error telling you to upgrade or disable the feature.

## Sessions overview (:AgentWorkbenchSessions)

When you run several sessions, `:AgentWorkbenchSessions` gives you a single dashboard of everything live. It lists active session buffers, including multiple sessions in one tab. Selecting a row activates that session in current tab. First entry focuses the prompt in Normal mode with History at latest output; later entries restore History at its last moved cursor.

- a single **status dot** at the left edge, colored and animated per state: blinking yellow while the agent works (in a background tab), slow-blinking in the compaction color while compacting, steady warning color when the session needs your attention, blinking green when a turn finished while you were in another tab, blinking red when the last turn errored (both consumed — back to idle — when you enter the tab), steady dim when idle, steady error color if the process died,
- the **session name** right after the dot: the backend session name (`:AgentWorkbenchSessionName`), falling back to the first user message, then `(unnamed)`,
- the **current session** marked on the dot itself: the dot of the tab you're looking at renders in the agent color — steady when idle, blinking while busy (same rhythm as the other dots, keeping the agent color) — while background sessions blink yellow while working. Each tab's view marks its own session and the marker follows tab switches — no extra text or UI elements.

The list is a single shared buffer (filetype `pi-sessions`): every tab that opens it gets its own window on the same buffer, so a status change redraws all open views at once. Updates are event-driven (agent start/end, compaction, session creation/teardown, attention requests, name changes) — nothing polls.

Keys inside the list: `<CR>` / `o` jump to that session's tab and open its chat using the latest-output or saved-History focus behavior, `r` renames the session under the cursor (same as `:AgentWorkbenchSessionName`, without leaving the list), `R` re-fetches session names, `?` toggles a shortcut help overlay, `q` closes the window.

By default the window follows the current tab's chat layout (a side split when the chat is in side layout, a centered float when it is in float layout); `mode` pins it to one style, and `auto_open` shows the list whenever the chat opens:

```lua
require("agent-workbench").setup({
    sessions_list = {
        mode = "follow",   -- "follow" | "side" | "float"
        auto_open = false, -- open the list together with the chat
        position = "left", -- side layout: "left" | "right" | "top" | "bottom"
        width = 40,        -- side layout width for left/right
        height = 12,       -- side layout height for top/bottom
        float = { width = 0.5, height = 0.4, border = "rounded" },
    },
})
```

The dot colors are driven by `PiSessionsList*` highlight groups (`Busy`, `Compacting`, `Pending` (attention), `Done`, `Error`, `Exited`, `Idle`, `DotDim`, `Current`) — see [Highlight groups](highlight-groups.md#sessions-overview).

## Compaction

Long sessions eventually run into the model's context window limit. pi delegates this to a **compaction** step: the backend summarizes older parts of the conversation and replaces them with the summary, freeing up tokens for new turns. pi supports both automatic and manual compaction.

- **Automatic compaction** is enabled at the backend level. When the conversation approaches the context threshold, pi compacts on its own and the `compaction` statusline component lights up (see [Statusline](usage.md#statusline)) — it renders the same 󰏗 icon as the compaction summary label while auto-compaction is on. `:AgentWorkbenchToggleAutoCompaction` / `pi.toggle_auto_compaction()` flips the setting on/off for the current session — the icon appears/disappears immediately and the backend session file records the change. With no active session the command is a silent no-op.
- **Manual compaction** — `:AgentWorkbenchCompact [instructions]` / `pi.compact(instructions?)` — triggers compaction immediately. If you pass custom instructions, they're forwarded to the summarizer to guide what gets kept:

```vim
:AgentWorkbenchCompact focus on architectural decisions and the reasoning behind them; drop intermediate tool outputs
```

Compaction can't run while the agent is streaming — wait for the current turn to finish (or abort it) first. Message submits during compaction are queued and sent after compaction finishes.

After successful compaction, Agent Workbench renders a collapsed summary block in chat history. Focus the block and press `<Tab>` to expand the backend-generated summary.
