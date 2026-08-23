# Changelog

## 2026-08-23

- **CHANGED:** History Markdown is now parsed per user message and per assistant text segment, then projected with Agent Workbench-owned Extmarks. Tool/thinking/status blocks never enter the Markdown parser, so malformed or unclosed Markdown cannot affect later messages; streamed updates recompile only the active block and raw transcript text remains unchanged.
- **BREAKING:** `render-markdown.nvim` and the whole-History builtin renderer are removed. Configure the new `render.markdown` feature/symbol schema and `AgentWorkbenchMarkdown*` highlight groups. Legacy `render.engine = "markview"` is temporarily accepted with a warning; `builtin` / `render-markdown` preserve raw text with an error, and `render.markview` is ignored.
- **CHANGED:** Markview is now used only through its documented parser API. Missing/incompatible Markview or Markdown Tree-sitter support leaves complete raw Markdown visible without interrupting chat, tools, replay, or session management.
- **FIXED:** Empty provider thinking envelopes no longer leave a folded `Agent Activity (empty)` section. Activity folds backed only by visible reasoning now summarize that reasoning instead of reporting `(empty)`, and thinking previews render strong, emphasis, strikethrough, and inline-code delimiters with plugin-owned structural styling.
- **FIXED:** Cursor movement no longer appears stuck inside concealed Markdown. The default Obsidian-style element reveal temporarily exposes only the heading, emphasis span, link, list item, checkbox, quote, code block, table row, or rule under the cursor without reparsing History; line-wide reveal and always-rendered modes remain configurable.
- **CHANGED:** Assistant text segments now use a subtle configurable left rail, making prose boundaries around tool and thinking blocks visible without adding full boxes or changing raw transcript text.

## 2026-08-20

- **ADDED:** Workspace sidebar `d` now confirms before closing a workspace tab, stops all sessions owned by it, preserves ordinary buffers, and refuses to close the last workspace.
- **FIXED:** Markview rendering and cursor-line conceal behavior now inherit the user's global configuration by default; optional `render.markview` values deep-merge over it only for Agent Workbench History buffers.

## 2026-08-19

- **ADDED:** History buffer titles now show the backend session name or first user message, stay synced after renames, and keep a bounded single-line fallback for bufferline and file-tree integrations.
- **FIXED:** Chat layout refreshes now skip unchanged window options and preserve configured expression folds, avoiding repeated full-History fold rebuilds.
- **FIXED:** Markview cursor refreshes now debounce rapid movement and drop pending work once History becomes hidden, avoiding redundant full-buffer renders.
- **FIXED:** Completing a staged History replay now restores the active chat component after deferred Markdown rendering without stealing focus from another view.

## 2026-08-18

- **ADDED:** Workspace sidebar session rows now support `p` to open a live History preview without switching workspaces or triggering `direnv` rebuilds.

## 2026-08-17

- **FIXED:** Persisted sessions now keep `Loading session…` visible while backend-authoritative messages rebuild in an offscreen History buffer through bounded timer slices, then reveal the complete transcript at once. Replay yields to Neovim between slices, native folds finalize once, and Markdown rendering runs after transcript installation, preventing both segmented History display and long main-thread freezes.
- **FIXED:** Background streaming now updates only its owning History buffer; scroll, fold, and Markview rendering no longer enter windows in inactive tabs, preventing visible buffer and workspace flicker when focus is elsewhere.
- **FIXED:** Explicit session activation and workspace-sidebar session creation now stay inside the owning workspace, while passive background History `BufEnter` events can no longer switch workspaces or rebind the foreground editor. History rendering also keeps the current cursor line in source form while surrounding Markdown stays rendered.
- **FIXED:** Attention requests from background sessions now stay queued instead of focusing that session's prompt and switching workspaces.
- **ADDED:** Reproducible VHS demo commands now generate overview and Shell Worksheet recordings for the README from the fixed Demo Neovim profile.
- **CHANGED:** README recordings now use descriptive sections and cache-safe asset names instead of opening with two unlabeled animations.

## 2026-08-16

- **ADDED:** Shell Worksheet now detects standard alternate-screen output and automatically opens the existing persistent PTY at its latest screen in a native terminal float for full-screen applications such as `btop`, `htop`, `fzf`, and `lazygit`. Leaving the alternate screen or ending the outer command restores the worksheet without restarting Fish; `<C-g>c` interrupts, `<C-g>p` returns early while leaving the program running, and Normal-mode `q` interrupts the program before closing the float.

- **FIXED:** Shell Worksheet now routes `<CR>` input to a running command's foreground PTY instead of rejecting it as a second command, enabling line-oriented nested shells and REPLs such as `nix shell`. Framed output now streams immediately while retaining only possible split marker bytes; commands remain line-oriented unless they enter an alternate screen, and hidden-password prompts remain unsupported in Worksheet input.

- **FIXED:** Select requests now consume RPC `optionDetails` metadata beside the backward-compatible string option list, preserving labels, descriptions, previews, and explicit values without encoding UI data in the title. Prompt keeps only the selected preview in a multiline virtual pane beside the options, preserves box/code formatting, and refreshes it during navigation; narrow windows stack the same preview below the list without flattening it. Embedded `--- N. ... preview ---` title blocks remain supported for older `ask_user_question` releases; confirming returns the option value or legacy string, never preview text.
- **FIXED:** Attention requests now open when focus is in History or another Agent Workbench window. Select/confirm requests move focus to Prompt automatically; free-form input/editor dialogs no longer require Prompt focus. Requests still queue when another request is active or compose draft protection applies.
- **FIXED:** `scripts/nvim-dev` now starts through `require("agent-workbench")`, avoiding the deprecated `require("pi")` startup warning and its `Press any key to continue` prompt.
- **FIXED:** Shell Worksheet now registers its Blink Fish completion provider through `agent-workbench.completion.shell`; the stale pre-rename `pi.completion.shell` path caused `module not found` errors from Blink cursor autocommands.

- **ADDED:** typing `/model` now opens model argument completion from the current RPC session, matching pi's TUI behavior. Available models are fetched once per live session, filtered locally as input changes, shown with model ID and provider, and inserted as canonical `provider/model-id` through built-in omnifunc or the optional Blink source.

- **CHANGED:** Agent sessions now start lazily by default. Opening Neovim or a new workspace tab no longer starts `pi --mode rpc`; set `auto_start_session = true` to restore one automatic visible session per workspace.

- **ADDED:** `:AgentWorkbenchReplaceSession`, `replace_session()`, and `/replace` start a fresh session in the current view, then stop the previous process and delete its live History buffer. Busy sessions refuse replacement. Existing `/new` and `:AgentWorkbenchNewSession` retain the current session and create another independent one.

- **CHANGED:** Agent Workbench is now a standalone GitHub repository rather than a member of the `pi2.nvim` fork network. Original Git history and attribution remain, while upstream updates are reviewed and ported selectively.

- **CHANGED:** The canonical Lua module moved from `require("pi")` to `require("agent-workbench")`, internal modules moved from `lua/pi/` to `lua/agent-workbench/`, and canonical commands now use `:AgentWorkbench*`. Deprecated `require("pi")`, `pi.completion.blink`, `:checkhealth pi`, and non-conflicting `:Pi*` command aliases remain until `2.0.0`; `pi-chat-*` filetypes and `Pi*` highlight groups remain unchanged for this migration phase.

- **CHANGED:** The project is now presented as **Agent Workbench**, an independent Neovim workbench for coding agents currently powered by pi.dev. The canonical repository is [saya-ashen/agent-workbench.nvim](https://github.com/saya-ashen/agent-workbench.nvim).

- **ADDED:** `flake.nix` and `flake.lock` provide a reproducible Linux development shell with Neovim, pi, Fish, packaged Plenary, formatting, lint, documentation, repository, and GUI-automation tools. `nix develop` sets `PLENARY_PATH`, so `make test` does not depend on plugins installed in the user's Neovim profile.

## 2026-08-14

- **CHANGED:** `!!` now opens a Neovim-native persistent fish shell worksheet in Prompt, not a raw terminal. Current input uses ordinary Vim editing; completed command/output blocks become read-only searchable lines, preventing edits and undo from corrupting prior results. `<CR>` executes the current cell from Normal or Insert mode, while Insert `<S-CR>` adds a newline for multi-line commands. Output streams through a virtual preview, exit/duration metadata stays virtual, multi-line result folds stay open until explicitly closed, and `<C-g>c` interrupts. `q` / `<C-g>p` preserve worksheet text, cursor, folds, and input undo while returning to compose; requests and layout changes suspend and restore the same worksheet. Initial `!!command` runs exactly once and places the cursor after the virtual `❯` prompt.

- **ADDED:** completed worksheet results now project ANSI 16/256/true-color styles and high-confidence unified-diff, URL, validated-path, and optional Tree-sitter JSON semantics through Neovim extmarks. Relative path validation follows persistent fish cwd changes, and path-looking filename fields receive probe priority before `ls -l` metadata. Optional `nvim-web-devicons` adds virtual file/folder icons without changing copied or searchable output; unsupported terminal controls safely retain Neovim's plain-text screen.

- **ADDED:** shell worksheet input now completes asynchronously from `fish complete -C` inside the same persistent Fish session, including current commands, options, functions, aliases, variables, cwd-relative paths, and user completion definitions. Installed blink.cmp receives a dedicated `pi_shell_fish` source and retains the user's normal Blink UI and keymaps; only the no-Blink fallback owns `<Tab>` / `<S-Tab>`. Pi prompt `/` and `@` sources stay disabled until compose mode returns.

- **CHANGED:** shell worksheet keeps the virtual `❯` prompt before running and completed commands, giving adjacent command results a shell-like visual boundary without changing copied or searchable command text.

- **CHANGED:** shell worksheet Normal-mode edit keys (`i`, `I`, `a`, `A`, `o`, `O`, `c`, `C`) now jump from completed commands or output to the current input and enter Insert mode. Inside the current input they retain native Vim behavior; colliding buffer-local mappings restore when worksheet mode closes.

- **CHANGED:** empty shell worksheet input now treats `<C-d>` like shell EOF and returns to compose without destroying the persistent Fish session. Historical rows and non-empty input retain native Vim `<C-d>` behavior; colliding buffer-local mappings restore on exit.

- **CHANGED:** Normal-mode `<C-c>` now interrupts a running shell worksheet command. While idle it retains native Vim behavior; Insert mode remains unchanged, and `<C-g>c` still interrupts from either mode.

- **FIXED:** moving through blink.cmp candidates in the Prompt or shell worksheet no longer inserts the highlighted candidate before explicit acceptance, even when global Blink `auto_insert` is enabled.

- **FIXED:** shell completion no longer presents Fish's structural `command link` type as if it were a command description. Real Fish descriptions, including option details from inputs such as `ls -`, now also populate Blink's documentation window.

- **FIXED:** shell completion no longer flashes between Blink's normal buffer sources and the asynchronous Fish source. Shell mode now enables only `pi_shell_fish`; compose and other buffers retain their original providers.

- **FIXED:** typing whitespace after a shell command now opens Fish argument and path completion immediately, including empty-token contexts such as `ls<Space>` and `git<Space>`.

- **FIXED:** shell completion keeps the currently typed short option token visible and first, and enriches its description from Fish's one-character-shorter completion query when Fish returns only longer prefixes. Parent results are cached across keystrokes, so `ls -la` no longer shows an older list before refreshing; exact Fish results are not duplicated.

- **FIXED:** agent completion notifications now disappear after three seconds instead of remaining open until the prompt receives focus.

- **FIXED:** unsent prompt drafts are now isolated by workspace and Neovim process. Concurrent instances no longer restore or overwrite each other's live drafts; later instances still recover drafts left by exited processes in the same workspace.

- **FIXED:** background sessions no longer ask markview.nvim to render hidden History buffers, preventing their decorations from leaking over unrelated windows such as Neo-tree. Hidden changes render when History becomes visible, while unchanged History buffers reuse their existing decorations instead of reparsing on every switch.

- **FIXED:** switching or resuming sessions now keeps History, prompt, and RPC ownership together. Prompt drafts cannot send until the backend session switch finishes, background output stays in its owning hidden History buffer, and late reload callbacks no longer replace the active session view. Session navigation now focuses the prompt with History at latest output on first entry, restores each History buffer's cursor and expanded/collapsed folds afterward, and keeps ordinary panel focus in Normal mode.

- **FIXED:** concurrent transcript resources for one session now receive unique readable History buffer names instead of raising `E95: Buffer with this name already exists`.

- **FIXED:** buffer-layout History now honors global `number` and `relativenumber` settings while restoring the editor buffer's local window options when chat closes.

- **FIXED:** workspace switches once again keep bufferline and native buffer navigation scoped to each tab without cross-assigning every listed buffer. The workspace sidebar still shows tracked buffers from every workspace, and opening a buffer or session with `l` / `<CR>` now reuses the existing editor or History window instead of creating an extra split and `No Name` buffer above the sidebar.

- **FIXED:** changing an idle workspace cwd now hands the visible History and prompt windows directly to the replacement session before stopping the old process, then deletes the stale History buffer so the previous session no longer remains in bufferline or workspace navigation.

## 2026-08-13

- **FIXED:** `make smoke` now runs hermetically against the current checkout with a stubbed RPC backend, without loading user config, starting real `pi`, or touching real sessions.

- **FIXED:** RPC transport failures now preserve unsent prompt drafts and attachments, avoid fake user/queue history, remove failed pending requests, keep matched responses out of the global event handler, and fail outstanding callbacks when the process exits unexpectedly.

- **FIXED:** changing an idle workspace with `:tcd` now replaces its active session with a fresh `pi --mode rpc` process started in the new cwd, so agent tools and persisted sessions no longer keep using the previous directory while the prompt winbar shows the new one. Streaming, compacting, retrying, or direct-bash sessions reject the change and restore their original cwd to avoid killing in-flight work.

- **FIXED:** `:PiAttention` now switches to the request's owning tab before activating its session. Workspace sidebar attention state outranks busy/compacting state, and deleting a session row asks for confirmation before stopping its process and deleting its History buffer.

- **FIXED:** persisted transcript opens now rebind session ownership and workspace metadata to the attached History buffer without deleting the old buffer.

- **FIXED:** accepting a pre-execution diff now stays open and sends no acceptance response when writing or closing the target file fails.

- **CHANGED:** Prompt shell prefixes are now persistent command modes. `!command` still runs through pi's backend, streams into chat History, joins the next LLM context, and resets the prompt to `!`; each submission uses a fresh backend shell. `!!command` now bypasses pi RPC and runs inside one persistent, session-local Neovim terminal, preserving `cd` / `export` state while keeping command output out of chat History and LLM context. Entering `!!` swaps the History area to that terminal; deleting back to `!` or normal text restores chat History. `<C-g>t` or `pi.focus_terminal()` focuses the terminal for interactive input.

- **CHANGED:** Completed full-block tools now keep their output folded by default, matching the pi TUI and preventing tool-heavy turns from flooding History. Tool names and argument summaries remain visible; complete output stays in the buffer and opens with existing `<Tab>` / native fold controls, while long output keeps its preview and read-only split flow. Inline tools such as `read` remain single-line.

- **CHANGED:** Extension select and confirm requests now switch their owning session's prompt into a read-only `request` mode instead of opening global `vim.ui.select`. Options stay visibly attached to correct agent/session, compose draft and cursor restore afterward, `<Esc>` cannot dismiss request, `<CR>` confirms, `<C-c>` explicitly cancels, and multiple requests drain per-session FIFO.

- **CHANGED:** Assistant turns now render separate **Agent Activity** and **Agent Output** sections. Thinking, tools, and intermediate prose fold when a turn completes, while final output stays open; the two most recent outputs remain expanded, older outputs age closed once, and manual reopen state is preserved.

- **FIXED:** Moving focus between prompt and History no longer reconfigures expression folds or closes the last open message block. Fold state now changes only through explicit fold commands and message lifecycle updates.

- **CHANGED:** Entering a session History buffer now leaves focus on History in Normal mode, matching normal Neovim buffer switching. History keys `i`, `I`, `a`, `A`, `o`, `O`, `c`, and `C` still focus the prompt and enter Insert mode explicitly.

- **ADDED:** `:PiWorkspaceSidebar` / `pi.workspace_sidebar()` now lists session History buffers and ordinary listed buffers together under each workspace. Session rows retain state icons and activation behavior; ordinary buffer rows show basenames, filetype icons/colors from optional `nvim-web-devicons`, modified state, and support `<CR>` / `l` switching plus `d` deletion. The native sidebar replaces the need for a separate buffer-list plugin or Neo-tree buffers source.

- **FIXED:** bufferline no longer disappears when Agent Workbench loads first. When bufferline later replaces Pi's temporary built-in workspace tabline, Pi now releases tabline ownership and stops applying its single-workspace `showtabline` rule, so listed file and session buffers remain visible.

- **FIXED:** Opening a normal file from a buffer-layout π panel keeps session and file buffers listed together; switching buffers restores chat History and prompt without creating an extra split.

- **FIXED:** Session History buffers no longer use internal `pi-session://<buffer-id>` names. They now show readable `π session <session-id>` names in bufferline and other buffer lists, while their `agent://...` transcript URI stays internal, preventing Neo-tree and similar file explorers from treating chat buffers as files outside cwd.

## 2026-08-12

- **FIXED:** opening buffer-layout chat over a `snacks.nvim` dashboard no longer aborts when the dashboard's `BufWipeout` cleanup raises stale-augroup `E367`; π retries that one failed buffer replacement without autocmds while preserving all other autocmd errors.

- **ADDED:** `:PiWorkspaceSidebar` / `pi.workspace_sidebar()` toggles a native collapsible workspace explorer. It shows short workspace names, full cwd paths, session counts, busy/attention state, and expandable live sessions with state-specific icons; `<CR>` switches, `o` switches and closes, workspace-row `h` / `l` toggle expansion, session-row `h` collapses and `l` activates, `a` creates a session, `A` creates a workspace, and `q` closes. Configure right/left placement and width with `workspace_sidebar`; no Snacks dependency.

- **CHANGED:** workspace tabs now show short cwd basenames by default and hide visible numeric indices; native click targets and `gt` / `gT` navigation remain unchanged. Full paths stay visible in `:PiWorkspaceSidebar`. `workspace_bar.label` accepts `"name"`, `"path"`, or a custom function, and `workspace_bar.show_index` restores visible indices.

- **CHANGED:** tab-backed workspaces now track buffer ownership without changing global `buflisted` state. File and π History buffers remain visible together in bufferline and `:bnext` / `:bprevious`; workspace ownership still controls moves and π History placement. One buffer may belong to multiple workspaces, while π History stays with its creating workspace. `:PiNewWorkspace` / `pi.new_workspace()` selects a directory before creating a rooted workspace; `:PiMoveBuffer {tab}` / `pi.move_buffer(tab)` moves an ordinary buffer. bufferline.nvim's right custom area shows workspace names, live-session counts, and aggregated busy/attention state without replacing bufferline or depending on `show_tab_indicators`; when no custom `tabline` exists, the built-in workspace bar provides the same data. Both support native mouse clicks and `gt` / `gT` switching. `:PiWorkspaces` / `pi.workspaces()` opens a searchable workspace picker; `pi.workspace_list()` and `pi.workspace_tabline()` support custom UI integrations. Configure with `workspace_bar` and `workspace_buffers`.

- **CHANGED:** sessions are now owned by listed History buffers instead of Neovim tabs. `:PiNewSession` creates a separate History buffer and `pi --mode rpc` process while existing sessions keep running; normal `:buffer`, `:bnext`, and `:bprevious` switches the complete chat view (History, prompt, and attachments) in buffer, side, and float layouts. Deleting a History buffer stops only its session; closing a tab only detaches the view. `:PiResume` activates an already-live session instead of opening the same JSONL in a second RPC process.

- **CHANGED:** `:PiResume`, `:PiContinue`, and persisted transcript opens now render the active session branch directly from local JSONL before the `pi --mode rpc` backend finishes starting. Replay suppresses intermediate scrolling and reveals the final message once; when RPC returns identical messages, the existing buffer stays in place instead of flashing through a second rebuild. The local read is preview-only and handles branched sessions plus legacy/current compaction checkpoints; changed authoritative state still replaces it, while unsupported, damaged, or legacy v1 files keep the previous RPC-only loading path.

- **CHANGED:** the `:PiSessionStats` context section now renders like the other sections — the `Context` title is its own highlighted header line, with the `tokens / window` line and the threshold-colored usage bar (with percentage) on separate lines beneath it, instead of one combined line.

- **ADDED:** `:PiSessionStats` / `pi.session_stats()` — a floating stats dashboard for the current session, mirroring the TUI's `/session` panel. It fetches `get_session_stats` (aggregates) and `get_entries` (full entry list) in parallel and shows: session file/ID; message counts; token usage with a `Cached`/`Uncached` split (hit rate, writes) when the provider reports cache activity; the total cost plus a **per-model breakdown** — each assistant response is attributed to its actual `provider/responseModel` (mid-session model switches show up as separate rows), tool results / compaction / branch summaries share a `Tools/summaries` bucket, and proportional bars are drawn per row (port of the TUI's `getUsageCostBreakdown`); a **Cache re-billed** line for prompt tokens that should have been cache reads but were re-billed (port of the TUI's `computeCacheWaste`, with the dollar figure derived from the session's own per-message cost breakdown instead of a model-pricing runtime); and context-window usage with a threshold-colored bar (yellow >70%, red >90%, same defaults as the statusline `context` component, `?` after compaction). Without an active session the command is a silent no-op; if `get_entries` fails it degrades to the aggregate view. New pure-logic module `lua/pi/stats.lua` (token formatting, breakdown, cache waste, dashboard rendering — all unit-tested) and one new highlight group `PiStatsBar`; `dialog.info()` gained an optional per-line highlight-ranges option. The statusline's `format_tokens` now comes from `pi.stats` (single source of truth) (#86).

- **ADDED:** `:PiToggleAutoCompaction` / `pi.toggle_auto_compaction()` — flips automatic context compaction for the current session on/off (session-level state is held by the backend; no new config). The command reads the current value via `get_state`, sends `set_auto_compaction` with the inverted value, and refreshes the statusline on success so the marker updates immediately; without an active session it is a silent no-op. The `compaction` statusline component is now part of the **default** layout (left group, after `queue`) — it existed as a built-in before but was never rendered unless users added it to `statusline.layout` themselves, which made the toggle's effect invisible out of the box. The component renders the 󰏗 `labels.compaction` icon (the same glyph as the compaction summary label) while auto-compaction is on, and nothing when it is off (#82).

- **ADDED:** `models` entries (the configured cycle/select shortlist) now accept a canonical `provider/modelId` reference — e.g. `"opencode-go/deepseek-v4-flash"` — in both the plain-string and `exact = true` forms, so model IDs that exist under several providers can be pinned to one provider instead of matching every copy. This mirrors the `--models`/`enabledModels` scoping syntax pi itself uses.

- **FIXED:** the double-`<Esc>` abort gesture was dead during the auto-retry backoff (the "Retrying…" state between `agent_end` and the retry's `agent_start`): the gesture only armed while streaming, and `_streaming` is false across the whole backoff window (default 2s/4s/8s… exponential), so an unrecoverable model error could not be interrupted by keyboard until the retry attempt actually started streaming. The gesture now stays live during retries via a dedicated `_retrying` state (kept separate from `_streaming`), and the second `<Esc>` sends the precise `abort_retry` RPC command — which only cancels the backoff, so the retry is cancelled and the failed turn ends — mirroring the TUI's retry escape handler. `:PiAbort` already worked during retries (core `abort()` includes `abortRetry()`); new `pi.abort_retry()` exposes the same command for scripts (#87).

- **CHANGED:** `:PiSelectThinking` / `pi.select_thinking_level()` now lists only the thinking levels the current model actually supports (fetched via the RPC `get_available_thinking_levels` command) instead of the hardcoded six-level list — no more picking a level the model rejects. If the backend fetch fails the picker falls back to the built-in list with a warning; on a model with no thinking support it warns instead of opening a picker (#81).

- **FIXED:** `:PiTree` failed on long sessions with `Failed to decode RPC message: Found too many nested data structures (1001)` and never opened the picker. Neovim's `vim.json` (lua-cjson) hard-caps JSON nesting at 1000 levels — a compile-time constant no runtime option can raise — and pi's `get_tree` response nests one level per session message, so any session of roughly 500+ messages exceeded the cap and the whole response was dropped. Incoming RPC lines that cjson refuses are now re-decoded with a new depth-tolerant decoder (`pi.json`, up to an 8000-level defensive cap, semantics matching `vim.json`: `null`→`vim.NIL`, `{}`→`vim.empty_dict()`, surrogate pairs in `\u` escapes), so `:PiTree` works for sessions up to ~4000 messages. The RPC debug log also no longer crashes when it tries to serialize a deep message.
- **FIXED:** `:PiDiff` showed the file list but not the diff content. The panel's outer container float (`focusable=false`) drew above the inner `focusable=true` floats at the same zindex, so Neovim skipped drawing the fully covered, non-focused diff float — the diff area showed whatever window was underneath (e.g. the chat panel). The container now opens at `zindex` 40, below the inner floats' default 50 (#16).
- **ADDED:** `:PiDiff` long diffs are now paged without leaving the file list: `<C-f>`/`<C-b>` page the diff area, `<C-d>`/`<C-u>` scroll it by half a page. Inside the diff area itself, all native scrolling still works (#16).

- **FIXED:** Idle detection is now driven by pi's authoritative `agent_settled` event instead of piecemeal restores. pi emits `agent_settled` only after the full session-level run settles — no retry, compaction retry, or queued continuation remains — but the plugin dropped it as an unhandled event (every finished conversation logged `UNHANDLED agent_settled`, plus a debug-mode warning). It is now the final fallback: any leftover spinner status is cleared and the sessions overview refreshed; a settle arriving inside the compaction rebuild window is buffered and applied after the rebuild. The `agent_settled` / `summarization_retry_*` event types are also annotated in `rpc.lua` (#84).

- **ADDED:** `summarization_retry_scheduled` / `summarization_retry_attempt_start` / `summarization_retry_finished` are now routed instead of logged as unhandled. During compaction, summary retries leave the ongoing `Compacting…` status untouched; while `:PiTree` generates a branch summary (`source: "branchSummary"`, agent idle), a `Summarizing branch…` busy state is shown and settles when the retry loop finishes. The transient error is surfaced in debug mode only (#84).

## 2026-08-11

- **FIXED:** File-tree reveal no longer treats `agent://...` transcript buffers as files outside the project cwd; history buffers keep their stable virtual URI but are now unlisted.
- **FIXED:** Streaming history no longer repeatedly mutates folds or status extmarks, reducing output jitter; long tool output now uses title, preview, and read-only split states, with independent structured `tool_batch` child summaries.
- **ADDED:** Native history folds now summarize messages, thinking, tool calls, and nested `tool_batch` items; prompt winbar shows live model, thinking, context, cwd, and run state.
- **ADDED:** Prompt completion now opens automatically for local/backend slash commands and `@` mentions; local `/new`, `/resume`, `/model`, `/thinking`, `/compact`, `/name`, `/session`, and `/abort` controls execute without backend round-trips.
- **CHANGED:** Expanded prompt statusline is disabled by default; busy and queue feedback follows latest history output, while abort hint/confirmation remains visible in prompt.

## 2026-08-10

- **ADDED:** `:PiDiff` / `pi.diff_review()` — session diff review. Opens one floating panel: an outer border and background frame the file list (`pi-diff-review` filetype, one `A`/`M`/`D` row per file changed by the current session — `session.changed_files`) on the left and the selected file's unified diff (`diff` filetype) on the right, so the whole review reads as a single UI. Moving the cursor in the list previews each file; `<CR>`/`o` jumps to the file — from the list to its first changed line, from the diff area to the exact line under the cursor (per-hunk line tracking; removed lines land on the deletion point, deleted files have no target) — and closes the review; `q` closes; closing any of the panel's windows closes the rest; re-running refreshes. Files the agent created render as full-file additions (git `--no-index`); files outside the git repo are skipped and counted in the list hint; hunk context follows `'diffopt' context:`. Sizing via the new `diff_review` config (`width`/`height`/`border` for the panel, `list.position`/`list.width` for the list area). Highlight groups: `PiDiffReviewFile`, `PiDiffReviewHint`, `PiDiffReviewFloatTitle` (#16).

- **CHANGED:** `:PiSelectModelAll` now opens its picker under its own title — `Select model (all)` — instead of sharing `:PiSelectModel`'s `Select model`, so the two pickers are distinguishable at a glance.

- **CHANGED:** Thinking blocks are now shown by default (`show_thinking` defaults to `true` instead of `false`). They used to be hidden by default because they can be noisy on verbose models; they are now visible out of the box, and `show_thinking = false` in `setup()` or `:PiToggleThinking` / `pi.toggle_thinking()` restores the old behavior at any time.

- **ADDED:** Dynamic `@mention` providers. Mentions are no longer limited to files: `@git-diff`, `@git-log`, `@lsp-errors`, and `@quickfix` now materialize live state — the current `git diff HEAD`, recent commits, ERROR-severity LSP diagnostics, and the quickfix list — and attach it to the message at send time as fenced `<context>` blocks appended after your sentence (the mention itself is lifted out). Providers that produce nothing vanish silently. They surface in `@`-completion ahead of file matches and highlight in the prompt like file mentions. Users can register their own via the new `mention_providers` config option — a `name → function returning text` map (or a spec table with `fn`/`description`/`lang`) — making any `@name` a custom context source. Output is trimmed and capped at 256 KB per provider; a provider that errors warns instead of breaking the send (#69).

- **CHANGED:** Documentation restructure. The README is now a landing page (intro, features, requirements, installation, quick start, config overview, commands, doc index, fork origin/differences); detailed guides moved to `doc/` — `usage.md`, `sessions.md`, `diff-review.md`, `attention.md`, `extensions.md`, `configuration.md`, `keymaps.md`, `api.md`, `highlight-groups.md`, `troubleshooting.md`. Content was re-verified against the current code along the way: panel title defaults (`prompt`/`attached`, not icon strings), `labels.error` (single warning glyph), the full highlight-group list (16 previously undocumented groups added, removed `PiStartupErrorLabel` which no longer exists), `set_session_name()` behavior (opens a prefilled dialog without an argument, never returns the name), the `pi-resume-session` dialog kind, the `pi-sessions` filetype, and the full `:checkhealth pi` check list. Also adds `make docs-links` (scripts/check_docs_links.py) validating relative links and anchors across README + doc/.

## 2026-08-07

- **FIXED:** Error blocks in the chat history no longer fall apart when the message is wider than the panel. The `▌` rail and the continuation indent were per-buffer-line extmarks, but long single-line errors — typically `429 data: {"error":…}` model-service failures — relied on the window's soft wrap, and soft-wrapped continuation screen lines started at column 0 with no rail, so the block looked like scattered fragments. Error text is now hard-wrapped to the history window width (display-width aware, never splitting a multi-byte char), so the rail runs down every screen line and wrapped chunks align under the first line; applies to mid-turn errors, inline system errors, and startup-preamble errors alike. The default `labels.error` also changes from a three-glyph cluster — two of whose codepoints render as tofu/hex boxes in common Nerd Font builds, making the prefix read as mojibake — to a single warning-triangle glyph.

## 2026-08-06

- **CHANGED:** In `:PiSessions`, the current tab's session dot now blinks while that session is busy. Previously the window-local current-tab marker rendered the dot steady in the agent color whether idle or busy; now the marker follows the blink animation (same rhythm as the other dots), so a working session you're looking at visibly pulses. The color is unchanged — the dot stays in the agent color, never the busy yellow; the dim phase falls through to the same dimmed state the other blinking dots use. Idle sessions keep the steady dot (#55 follow-up).

- **ADDED:** `:PiSessions` can rename sessions in place: `r` on a row prompts for a display name (prefilled with the current backend name) and sends it to that session's backend over RPC — no need to jump to the session's tab first, and it works for any listed session, current tab or not. The row updates through the backend's `session_info_changed` event, so every open list view refreshes at once. Renaming a session whose process exited is refused with a warning (#61).

- **CHANGED:** In `:PiSessions`, the manual refresh (drop cached names and re-fetch) moved from `r` to `R`; `r` is now rename. The `?` help overlay lists both bindings (#61).

- **FIXED:** `:PiSessions` could list sessions in the wrong order — e.g. tabs 2 and 3 swapped — because the list was sorted by tabpage handle (creation order), which stops matching the tabline once a tab is created mid-list (`:tabnew` inserts after the current tab) or tabs are rearranged with `:tabmove`. The list now follows the tabline's visual order (#63).

- **FIXED:** `gf` on a path in the chat crashed with `E1513: Cannot switch buffer. 'winfixbuf' is enabled` when the session list was the only non-chat window in the tab — the target-window scan did not recognize the session list filetype and never checked `winfixbuf`. π panels, the session list, and any `winfixbuf`-pinned window are now skipped; with no eligible window the file opens in a fresh split (#62).

- **FIXED:** A regression from the `(unnamed)` flicker fix: session names in `:PiSessions` only appeared when a turn *ended*, so long turns kept the row on `(unnamed)` the whole time. The backend buffers session entries and flushes them to disk when the *first assistant message* completes, so the first-user-message fallback becomes readable mid-turn — unresolved names are now retried on every `message_end` (cheap: a no-op once resolved, no timers), with the `agent_end` retry kept as a backstop. Also, a `get_state` answer arriving while a fetch is in flight no longer clobbers a name that `session_info_changed` set meanwhile (#60, follow-up to #58).

## 2026-08-05

- **CHANGED:** Every selection list now renders through `vim.ui.select` instead of the plugin's own float picker, so all lists — thinking level (`:PiSelectThinking`), curated model pick (`:PiSelectModel`), diff review-note pickers, and extension `select`/`confirm` attention requests — appear in whatever picker you have configured (telescope's `ui-select`, snacks.nvim, the built-in picker…), with its filtering and keymaps. Previously only the sessions list, the all-models picker, and the tree pickers did this; the rest were a self-drawn float with fixed `j`/`k`/`<CR>` keys. Each call passes a stable `kind` (`pi-thinking-level`, `pi-model`, `pi-diff-note`, `pi-extension-select`, `pi-confirm`) for per-source backend customization. Visible consequences: confirm dialogs (`Yes`/`No`) lose their `y`/`n` one-key shortcuts; the thinking-level and curated-model pickers no longer preselect the current value (the picker opens at the top — fuzzy-filter instead); extension select/confirm requests no longer auto-close when their timeout elapses while the picker is open (a late response is dropped with an "expired" notice, same as before); review-note options drop their `1.`/`2.` number prefixes. Config: `dialog.indicator`, `dialog.keys.next`, and `dialog.keys.prev` are removed (they only styled the old float); `dialog.keys.confirm`/`cancel` stay — they still drive the input/editor and info floats, which remain self-drawn (#59).

- **FIXED:** `(unnamed)` rows in the session list (`:PiSessions`) no longer flicker between `(unnamed)` and the `…` pending placeholder every few seconds. Entries that resolved empty were retried on *every* redraw, and each retry swapped the cache back to the in-flight placeholder — a self-sustaining fetch → refresh → redraw → fetch loop that also polled the backend with pointless `get_state` calls for as long as the list was visible. Empty entries now keep showing `(unnamed)` while a background retry runs (only the very first fetch shows `…`), and retries happen only on meaningful transitions — a finished agent turn (when the first user message or a backend name may have appeared), session create/resume invalidation, and manual `r` — never on redraws (#58).

- **FIXED:** Resuming a session (`:PiResume`, `:PiContinue`, compaction rebuild) no longer loses thinking content. `replay_messages` dispatches `on_thinking_start/delta/end` for every assistant message synchronously back-to-back, but the coalesced thinking-delta queue was a single global list with no block attribution — so the first block's scheduled start callback drained *all* queued deltas: the first block showed merged thinking while every later block froze empty (`Thought for 0s` with no content, exactly what a resumed session looked like). Deltas are now tagged with their block's generation at dispatch time (`_pending_thinking` is keyed by generation) and each accumulator drains only its own chunks; live streaming is unchanged, where deltas attribute to the active block as before.

- **FIXED:** Resumed thinking blocks no longer show a fabricated `Thought for 0s` header. The duration was never stored in the session file (thinking parts carry no timing field, and message `timestamp`s mark message creation, not the thinking phase), while the header's elapsed time was measured live at render time — replay dispatches start/end back-to-back, so it always read 0s. Replayed blocks now freeze with a bare `Thought` header (content, preview, and expand/collapse unchanged); live streaming still shows the measured `Thought for Ns`.

- **FIXED:** The agent timestamp label no longer leaves a two-blank-line gap when the turn opens with a tool block, inline tool, or thinking block instead of streamed text — the label now ends with exactly one trailing blank line (the same rhythm text followers already had), so spacing under every timestamp line is uniform.

- **ADDED:** `?` in the session list (`:PiSessions`) toggles a help overlay listing the list's shortcuts (`<CR>`/`o` open the session under the cursor, `r` refresh, `q` close, `?` help). The overlay is a non-focusable float — it never steals focus from the list — is tracked per list window (each tab's view toggles its own), and closes automatically when its list window closes (#56).

## 2026-08-04

- **ADDED:** `:PiSessions` marks the current tab's session on the dot itself: that dot renders steady in the agent color — no blink — whether idle or busy, while busy sessions in background tabs blink yellow. The buffer is shared across tabs but the marker is window-local, so each tab's list view points at its own session and follows tab switches; no new text or UI elements (#55).

## 2026-08-03

- **ADDED:** `:PiSessions` / `pi.sessions()` — a live, read-only overview of all active π sessions (one per Neovim tab). Each row shows the tab number, the session's status as a single dot at the left edge whose color and animation encode the state (blinking while busy, slow-blinking while compacting, steady warning color when attention is needed, blinking green when a turn finished in another tab, blinking red when the last turn errored — both consumed when you enter the tab — steady dim idle, steady error exited), with the session name right after the dot — the backend session name set via `:PiSessionName`, falling back to the first user message, then `(unnamed)`. The list is a single shared buffer: every tab that opens it gets its own window on the same buffer, so one redraw updates every open view at once. Updates are event-driven (agent start/end, compaction, session create/teardown, attention requests, and `session_info_changed` name changes) — nothing polls. Keys: `<CR>`/`o` jump to a session's tab and open its chat, `r` re-fetches names, `q` closes. The window style is configurable via the new `sessions_list` config: `mode` (`"follow"` the tab's chat layout by default, or pinned `"side"`/`"float"`), `position`/`width`/`height` for the side split, `float` for the floating window, and `auto_open` to show the list whenever the chat opens (#54).

## 2026-08-02

- **ADDED:** Dedicated history renderers for the four [pi-web-access](https://github.com/nicobailon/pi-web-access) tools (`web_search`, `fetch_content`, `source_check`, `get_search_content`), which previously fell through to the default renderer. Each now gets its own nerd-font icon (web / shield-check / database-search; `web_search` keeps its magnifier) and a deterministic input summary line: the `query` or up to three `queries` joined with ` · ` (longer lists truncate as `…(+N)`), the `url` or each `urls` entry on its own line, the `claim`, and `responseId` plus whichever selector is present (`query` / `queryIndex` / `url` / `urlIndex`) — instead of the default renderer's unordered first-string pick. Collapse thresholds match the default (1/1), so their characteristically long outputs (search answers, full-page markdown, check artifacts, content slices) auto-collapse with `<Tab>` expand, same as before. Tools from other extensions and all existing renderers are unaffected (#51).

## 2026-08-01

- **CHANGED:** The chat history is now rendered through [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) by default (`render.engine = "render-markdown"`), giving rendered headings, list bullets, code-block chrome and links out of the box; tool output stays fenced so shell content is not misparsed as markdown. render-markdown.nvim is therefore now a dependency of the default setup (add it to your plugin spec — see the README install examples). Set `render.engine = "builtin"` to keep the previous treesitter + custom-drawing renderer. If the default engine is active but render-markdown.nvim is not installed, pi warns once and falls back to the builtin renderer, so existing setups without the plugin keep working.

## 2026-07-31

- **FIXED:** `:PiTree` / `pi.tree()` is readable again on long sessions. The picker indented every entry by its position in the conversation, so a long linear session (where each entry has a single child) accumulated dozens of indent levels and pushed the preview text — and the trailing branch label — off the right edge of the picker, making later entries invisible. Indentation now tracks *branching* instead of length: a node's children are only nested one level deeper when there is more than one of them (a genuine fork); a single child is just the conversation continuing and stays at the same depth, so a linear session renders flat at the left edge (matching the pi TUI's flat `/tree` layout) while real branches still nest under their fork point. The branch label (`⚑ …`) also moved from the end of the line to right after the `[kind]` tag, before the preview text, so it stays visible even when a long preview is truncated. The same picker also stopped showing blank `(no text)` lines for the assistant turns that only call tools (the majority of turns in a tool-heavy session): those now render a compact tool-call summary — the chat's per-tool nerd-font icon as a lightweight marker plus the first argument (the bash command, edited/read path, search pattern, …; extra tools on one turn fold into `(+N)`) — and aborted or errored turns show `(aborted)` / `(error: …)`, matching the pi TUI's `/tree` where every line carries content.
- **CHANGED:** `:checkhealth pi` now covers optional dependencies and runtime features: treesitter `markdown`/`markdown_inline` parsers, `img-clip.nvim`, `render-markdown.nvim` (warns when configured but missing), `blink.cmp`, the bundled `extensions/tree.ts`, and image compression tool availability (`sips`/`magick`/`ffmpeg`). The Neovim < 0.10 check is now an error instead of a warning, matching the stated requirement.
- **FIXED:** `config.lua` type annotations: `turn_separator` described a "thin ─ line" but the implementation inserts a blank line; `StatusLineComponents` was missing the `queue` field; `StatusLineBuiltinName` was missing `"queue"` and `"spinner"`.
- **FIXED:** A thinking block no longer leaves a two-line gap before a following tool or direct `!` bash block. The block used to emit two trailing blank lines and rely on the next *text* delta reusing one — but tool/bash blocks reuse none, so they sat two blank lines below the `󰟶 Thought for Ns` header while text sat one. The thinking block now ends the way a tool block does (one trailing blank + the breathing-line flag), so text, tool blocks, bash blocks, inline tools, and consecutive thinking blocks all sit exactly one blank line below it. Thinking → text spacing is unchanged (still one blank); expand/collapse, the streaming preview, and hidden thinking (`show_thinking = false`) are unaffected.
- **CHANGED:** History rendering got a visual polish (styling only — no behavior, config, or collapse-threshold changes). A tool block (and a direct `!` bash block) now reads as one continuous container: the header and footer lines share the same `PiToolBody` background as the body, so the color band runs unbroken from header top to footer bottom instead of splitting into a transparent header, a banded body, and a dangling footer. Text hierarchy is clearer: tool input (`PiToolCall`) is promoted to the main body level (normal text color) while output/summary/metadata stay receded `Comment` italic. Thinking blocks separate label from content — the collapsed single-line preview now uses the new `PiThinkingPreview` group (subdued italic) while the header keeps `PiThinking`. Inline diff signs are now semantic: the line number stays gray (`PiDiffLineNr`) but the `+`/`-` sign itself takes the diff color via the new `PiDiffAddSign` / `PiDiffDeleteSign` groups (foreground derived from `DiffAdd`/`DiffDelete`, falling back to the `diffAdded`/`GitSignsAdd` semantic hue). All new groups are `default = true` and work under both the builtin and render-markdown engines.
- **ADDED:** Image attachments can now be compressed before sending (`prompt.image_compress`, enabled by default): downscaled to `max_dimension` on the longest side (1568px by default) and optionally re-encoded (`format`, `quality`) via an external tool — auto-probed `sips` (macOS built-in) → ImageMagick `magick` → `ffmpeg`. Compression is asynchronous and never blocks paste; it applies to clipboard pastes and, with `scope = "all"` (default), to dropped/`:PiAttachImage` files as well. `svg` and `gif` are never touched, an unavailable tool falls back to the original silently, a failed run falls back with a warning, and a result that would not be smaller than the input is discarded. The size shown in the attachments panel is the post-compression size.
- **ADDED:** The attachments panel now shows each image's byte size next to its name (e.g. `󰫮 shot.png (1.2 MB)`) — the size of the data that will actually be sent with your next message. The suffix uses the new `PiAttachmentSize` highlight group (linked to `Comment` by default).

- **FIXED:** Buffer reload after pi edits a file now works when the reported path goes through a symlinked directory (e.g. `/tmp` on macOS, where `/tmp` → `/private/tmp`, or a symlinked project root). `reload_buffers` matched pi's paths against buffer names with `fnamemodify(..., ":p")`, which makes a path absolute but does not resolve symlinks, while Neovim buffer names are always resolved — so buffers under symlinked directories were silently never reloaded, leaving stale content on screen. Both sides are now compared by canonical path (`fs_realpath`, falling back to the absolute form for deleted files); the `reloaded`/`skipped` summaries still echo the paths exactly as reported.
- **FIXED:** The unit test suite (`make test`) is green on macOS again — 12 pre-existing failures in `reload_spec`, `session_list_spec`, and `files_cache_spec`. The specs computed expected paths from `vim.fn.tempname()` and `/tmp` literals, which keep the unresolved form, while the modules under test see symlink-resolved paths from `getcwd()`/buffer names. The specs now normalize paths through `vim.uv.fs_realpath()` before use; no assertions were weakened, and the normalization is a no-op on Linux.
- **ADDED:** `:PiTree` / `pi.tree()` — session tree navigation, the π equivalent of the TUI's `/tree`. Pick any past conversation point from a picker (depth-indented, current point marked `●`, branch labels shown), choose whether to summarize the abandoned branch (No summary / Summarize / Summarize with custom prompt), and the backend moves the session leaf and rebuilds the chat from the new branch; picking a user message puts its text back in the prompt for editing. Typing a bare `/tree` in the prompt also opens it. Requires a pi version whose extension API exposes `ctx.navigateTree`; can be disabled with `tree = { enabled = false }`.

## 2026-07-30

- **CHANGED:** The history panel's `π` title no longer uses inverted colors (colored background with dark text). Both the side-layout winbar title (`PiChatHistoryWinbarTitle`) and the float-layout title (`PiChatHistoryFloatTitle`) now render as bold colored text on the normal background, matching the other panel titles. Override either group to restore the badge look.
- **FIXED:** The first line of an assistant reply no longer renders above its response header (the icon + timestamp line). When a response starts with text, the header and the first streamed chunk are dispatched back-to-back; the stream coalescing could hand that first chunk to the header's render pass, so it landed one batch too early — above the header — while the rest streamed below. The batch queue now always keeps an open tail batch, restoring the seal/pop ordering guarantee; streamed text, thinking blocks, and tool blocks still land in exact RPC dispatch order.
- **FIXED:** Chat colors now refresh when you change the Neovim colorscheme. The `Pi*` highlight groups are derived from the active theme but were installed with `default = true`, which never overrides an existing group; legacy colorschemes call `:highlight clear` and masked the problem, but modern ones (tokyonight, catppuccin, …) do not, so the groups stayed frozen at the first theme on `:colorscheme`. π now clears its own default-defined `Pi*` groups before re-deriving them on each `ColorScheme` event. Explicitly user-defined `Pi*` groups are left untouched and keep priority.

## 2026-07-29

- **FIXED:** Typing in the prompt no longer stalls periodically in large projects. The shared project-file cache (used by `@`-mention completion and prompt decorators) refreshed by running `git ls-files` *synchronously* whenever its 5s TTL expired, blocking the main loop for ~28ms in a 20k-file repo (and hundreds of ms in huge ones) — once per expiry, mid-keystroke. The cache is now stale-while-revalidate: an expired cache is returned immediately and refreshed asynchronously in the background (single-flight, result dropped if the cwd changes), so the expired-path cost drops from ~28ms to ~0.05ms. Only the very first listing per cwd still fetches synchronously, and `exists()` never blocks at all (cold cache falls back to an on-disk check while the refresh runs).
- **FIXED:** `@`-file completion is responsive while typing in large projects. The matcher re-lowercased the query and every candidate path on every keystroke and fuzzy-scanned the entire file list with no result cap — ~7ms per keystroke in a 20k-file repo (13–16ms at 50k files). The query is now lowercased once, lowercase paths are computed once per cache generation (memoized on the file-cache identity), the fuzzy scan is anchored on a C-speed `find()` of the first query character and stops after 100 fuzzy results (menus display far fewer; the source already declares the list incomplete). Per-keystroke cost in a 20k-file repo drops 2.5–18× (worst-case no-match query 5.6ms → 1.0ms; typical queries 6–7ms → ~0.5ms). Prefix matching, directory collapsing, result ordering within the cap, and case-insensitive fuzzy semantics are unchanged (verified differentially against the old implementation).
- **FIXED:** Chat streaming is dramatically cheaper on the main loop. Every streamed token (text, thinking, bash output, tool live updates) used to schedule its own callback and buffer write — hundreds of scheduled callbacks and one screen redraw per token at model streaming rates, starving input handling and other plugins while a fast model responded. Deltas are now coalesced and flushed at most once every 30ms: a 3000-token response drops from ~3000 scheduled callbacks/buffer writes to ~30, the per-token Lua work in the render path falls ~200x, and the number of screen updates delivered to the terminal falls ~8-20x. Stream ordering is preserved exactly (text, thinking blocks, tool blocks, and bash output land in RPC dispatch order), and the `on_thinking_end` no-op that was scheduled before every text token is gone.

## 2026-07-28

- **FIXED:** The plugin failed to load at all on Neovim stable releases (0.10/0.11): the thinking-preview tail walker used the Lua 5.3 bitwise operator `&`, which the LuaJIT embedded in stable builds cannot parse, so one syntax error in `lua/pi/ui/chat/text.lua` cascaded into `Failed to run 'config' for Agent Workbench` at startup and `loop or previous error loading module 'pi.sessions.manager'` on every toggle. The check is now a plain byte-range comparison that every Neovim build parses. (Recent nightly builds were unaffected: their newer LuaJIT accepts 5.3 bitwise ops, which is how this went unnoticed.)
- **FIXED:** The paste interception no longer affects paste outside of π. Previously two separate global `vim.paste` overrides were installed — one at setup and another re-wrapped around the last on *every* prompt creation (and never removed), so the editor's global paste handler was permanently modified and the wrappers accumulated across sessions. There is now a single, idempotent wrapper that short-circuits on the current filetype: any paste outside a π prompt buffer is a pure pass-through that runs no π logic at all (no clipboard query, no `fs_stat`). Clipboard-image attach and drag-and-drop image-path attach inside the prompt are unchanged.
- **FIXED:** The pending steer/follow-up queue display now stays in sync with pi's authoritative queue state. π used to track the queue purely by local inference (add on send, remove on delivery, drain on `agent_end`) and ignored the backend's `queue_update` events, so messages queued from outside the plugin (e.g. by extensions) never appeared, and entries pi dropped through untracked paths could linger as ghosts. `queue_update` is now handled: payload items missing locally are synthesized into the queue display, and — when the agent is idle, so no delivery can still arrive — locally tracked entries pi no longer holds are swept. Delivery (`message_start` arrives right after the event) and abort (`agent_end` flush) behavior is unchanged.

## 2026-07-27

- **ADDED:** Per-tab model pinning. The pi backend persists every model switch to its global settings and resolves fresh conversations from there, so a model switch in one tab used to leak into every other tab's next `:PiNewSession` (and any newly opened tab). π now pins the model per tab: the pin is captured when the session starts, updated whenever you switch the model in that tab (`:PiCycleModel` / `:PiSelectModel` / `:PiSelectModelAll`), and reapplied after `:PiNewSession` so the tab's new conversation keeps the tab's model. Resumed sessions adopt the model restored from their session file. If the pinned model becomes unavailable, π silently falls back to the backend's choice and adopts it as the new pin. Brand-new tabs still follow pi's normal initial-model resolution.
- **CHANGED:** The busy spinner, elapsed time, and abort hint/confirmation moved from virtual lines at the end of the history buffer into the prompt statusline, where they have a fixed position that never scrolls away with the history. The statusline layout gains a `center` group (default `{ "spinner" }`) with placement priority over the left/right groups; the transient abort rows temporarily replace the spinner there (`Aborted` > hint > spinner). New built-in components: `spinner` (busy display with elapsed time and thinking state) and `queue` (pending steer/follow-up count, `⏵ N`). The pending-queue *preview* rows stay at the end of the history but no longer pad themselves to the viewport bottom — they simply follow the content.
- **FIXED:** Thinking blocks no longer have a large gap between the header and the busy spinner: the spinner moved into the prompt statusline, so nothing renders beneath the block anymore. (The block's two-blank trailing margin is unchanged — the next text delta reuses the final blank, settling to exactly one blank line of separation.)
- **FIXED:** Streaming no longer rebuilds the history status block on every delta: with an empty queue the per-delta status update is a cheap no-op, and the whole-buffer `nvim_win_text_height` scan is gone from the history hot path entirely (the prompt statusline applies the same skip-when-full guard, keeping the spinner tick O(1) even with huge pasted prompts).

- **ADDED:** `quickfix` config option. When pi's `grep` tool finishes, its matches are parsed (`path:line[:col]: text`) and loaded into the quickfix list so you can jump between them with `:cnext` / `:cprev`; the `find` tool's file list can be loaded the same way. The list is titled `pi <tool>: <pattern>` and is never opened automatically (use `:copen`). Defaults: `grep = true`, `find = false`, `glob = false` (`glob` is an alias of `find` for older pi versions).

- **FIXED:** Chat no longer stutters once the history grows large, and large-session replay is faster. The status block (spinner / pending queue / abort hint) recomputed its bottom padding with a whole-buffer `nvim_win_text_height` scan on every streamed token and every spinner tick — O(history size) each, which saturated the main loop on big sessions. The scan is now skipped whenever the conversation provably fills the window.
- **ADDED:** `reload.mode` config option. When pi's `edit`/`write` tool modifies a file that is open in a Neovim buffer, Agent Workbench now automatically reloads it. `"silent"` (default) reloads unmodified buffers quietly; `"notify"` also shows a notification; `false` disables the behavior. Modified buffers (unsaved user changes) are never touched.
- **FIXED:** Opening the resume-session picker (and the continue-session lookup) no longer takes many seconds on projects with large session files. Session listing had regressed to JSON-decoding *every* line of *every* `.jsonl` just to find the latest session name; it now decodes only the rare, small `session_info` lines (cheap substring prefilter) and stops decoding message lines once the first user message is found, keeping listing I/O-bound. The "latest name wins" behavior is unchanged.
- **FIXED:** Loading/resuming a large session is much faster. A `get_messages` response is a single multi-MB JSON line, and the RPC stdout reader rebuilt the growing partial line via repeated string concatenation on every incoming chunk — an O(n²) that took ~2s for a 20MB session (and quadratically worse for bigger ones). Partial lines are now buffered as a list of chunks and concatenated once when complete, cutting the `get_messages` round-trip to a few hundred ms.
- **FIXED:** Loading a large session no longer hangs (and scrolling/paging is responsive again) when using the `render-markdown` engine. render-markdown.nvim re-renders the whole history buffer on every change, and a session replay makes hundreds of buffer edits, so each edit re-parsed the growing buffer (O(n²)) and saturated the event loop — a 23MB session could hang indefinitely. pi now pauses render-markdown for the history buffer while replaying and re-enables it (rendering once) after the edits land.

- **FIXED:** The spinner, pending-queue, and abort-hint status no longer cover history content. The pinned floating overlay introduced on 2026-07-25 is replaced by virtual lines at the end of the buffer, so a freshly sent message and any scrolled-up content are never hidden behind it; when the conversation is shorter than the window the status is padded to sit flush against the bottom edge.
- **FIXED:** The streaming thinking header no longer flickers between one and two wrapped lines. The rolling preview is now end-of-line virtual text (`eol`) instead of `inline`, so it no longer counts toward the header's wrap width.

## 2026-07-26

- **ADDED:** Direct bash mode — prefix the prompt with `!` to run a shell command (e.g. `!ls -la`). Output streams live into a collapsible block in the history, and the result is added to the LLM context on the next prompt. At release time, `!!command` excluded output from context; persistent local-terminal semantics replaced that behavior on 2026-08-13. The prompt panel title switches to `bash` (configurable via `panels.prompt.bash_title`) with a distinct foreground color while in bash mode. A single `<Esc>` cancels a running `!` command (`:PiAbortBash` / `pi.abort_bash()`). Bash execution messages replay correctly on session load/switch.
- **ADDED:** Pasting into the prompt now auto-attaches clipboard images. π wraps the global `vim.paste` handler: when the system clipboard holds an image, it is attached (as with `:PiPasteImage`) and the text paste is cancelled; any other paste is inserted as usual. Requires `img-clip.nvim`. Reliable for GUI paste; in a plain terminal use `:PiPasteImage` explicitly. Disable with `prompt.paste_image = false`.
- **CHANGED:** Completed inline tools (e.g. `read`) now keep their colored header highlight instead of fading to muted gray, matching the behavior of block tools (`bash`, `edit`, `write`).
- **FIXED:** Tool output no longer gets misparsed as markdown headings when using the `render-markdown` engine. Output is now wrapped in code fences in both expanded and collapsed views to prevent setext heading syntax (e.g. `===` lines) from triggering.
- **FIXED:** Tool block expand/collapse round-trips no longer corrupt the footer extmark anchor, preventing toggle failures after multiple collapse/expand cycles.

## 2026-07-25

- **ADDED:** `layout.side.position` now supports `"left"` to open the side panel on the left edge of the editor.
- **ADDED:** Double-`<Esc>` aborts the running agent (same as `:PiAbort`). The first `<Esc>` arms the gesture and shows a persistent hint row in the bottom status overlay; a second `<Esc>` within `abort.timeout` ms aborts. Configurable via the new `abort` option (`enabled`, `timeout`, `message`).
- **ADDED:** Aborting a turn now shows a brief centered **Aborted** confirmation in the status overlay, and the in-history completion marker (`· aborted` / `· failed`) uses a prominent highlight (`PiAborted` / `PiError`) instead of the muted busy color.
- **CHANGED:** Status spinner and pending-queue display moved from virtual lines to a pinned floating overlay at the bottom of the history viewport.
- **CHANGED:** Per-tool icons in tool headers; completed inline tools fade to a muted style.
- **FIXED:** Thinking preview no longer corrupts non-ASCII text (CJK, emoji) when truncating to fit the display width.
- **FIXED:** A thinking block following an inline tool (e.g. `read`) no longer renders *before* it. Thinking blocks now always anchor after the preceding content, so a `thinking → tool → thinking` turn renders in the correct order instead of `thinking → thinking → tool`.

## 2026-07-24

- **CHANGED:** Replace box-drawing tool block borders with fold indicators (`▾`/`▸`) and indentation for a cleaner, less noisy layout.
- **CHANGED:** Successful tool calls now end silently; only errors show a status footer.
- **ADDED:** Animated spinner on running tool header rows (`PiToolRunning` highlight).
- **CHANGED:** Thinking blocks render as a single header line with an inline rolling preview; press `<Tab>` to expand/collapse.
- **CHANGED:** `pi.toggle_history_blocks()` now also toggles thinking blocks.

## 2026-07-08

- **FIXED:** Show the assistant header before tool-only turns so tool calls do not appear under the user message.

## 2026-07-04

- **FIXED:** Make chat timestamp format configurable with `timestamp_format` option and use a platform-specific default to avoid the GNU `%-d` flag on Windows.
- **FIXED:** Use cross-platform path joining for session directories and file globbing (Windows compatibility).

## 2026-07-03

- **ADDED:** Add RPC adapter hooks for user-land command/event mapping of non-upstream-compatible backends.
- **FIXED:** Reject failed multi-edit diff reviews instead of opening an empty diff.
- **FIXED:** Suppress debug warnings for known redundant session state events.

## 2026-06-21

- **ADDED:** Add RPC adapter hooks for user-land command/event mapping of non-upstream-compatible backends.
- **ADDED:** Add configurable diff review keymap hints with `?` help, winbar hints, and disabled mode.
- **FIXED:** Restore diff review buffer-local keymaps after accept, reject, timeout, or manual tab close.

## 2026-06-18

- **BREAKING:** Change diff review note payloads to use `lineStart`, `lineEnd`, and `lines` instead of `line` and `lineText`.
- **ADDED:** Add range-based diff review notes with visual-line selection, wrapped note text, overlap handling, and multiline note input.
- **CHANGED:** Wrap markdown diff review panes for readability while preserving global wrapping defaults for other filetypes.
- **FIXED:** Keep the chat spinner visible when an automatic retry resumes agent work.

## 2026-06-17

- **ADDED:** Add `pi.scroll_chat_history_to_first_agent_response()` to jump to the first assistant response in the latest user turn.
- **ADDED:** Render live tool progress updates inside chat history tool blocks.
- **CHANGED:** Make `pi.scroll_chat_history_to_last_agent_response()` target the last assistant response in the latest user turn.
- **FIXED:** Give each assistant text message its own chat history response header while suppressing empty tool-only headers.
- **FIXED:** Prevent tool output containing NUL bytes from crashing collapsed history rendering.

## 2026-06-16

- **ADDED:** Add line-level notes to diff review, including note keymaps, configurable note icon, and note-aware review responses.
- **ADDED:** Add `pi.toggle_history_blocks()` to expand/collapse all expandable history blocks.

## 2026-06-15

- **BREAKING:** Replace `setup({ bin = "pi" })` with `setup({ cli = { bin = "pi", args = {} } })`.
- **ADDED:** Add `cli.args` for extra pi RPC startup arguments.
- **ADDED:** Render compaction summaries after successful compaction.
- **ADDED:** Queue message submits while compaction is running.
- **FIXED:** Handle current `compaction_start`/`compaction_end` RPC events.
- **FIXED:** Preserve message ordering and queued output during compaction replay.
- **FIXED:** Keep agent markdown fence auto-closing isolated from tool output.
