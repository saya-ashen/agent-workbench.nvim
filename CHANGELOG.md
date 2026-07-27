# Changelog

## 2026-07-27

- **CHANGED:** The busy spinner, elapsed time, and abort hint/confirmation moved from virtual lines at the end of the history buffer into the prompt statusline, where they have a fixed position that never scrolls away with the history. The statusline layout gains a `center` group (default `{ "spinner" }`) with placement priority over the left/right groups; the transient abort rows temporarily replace the spinner there (`Aborted` > hint > spinner). New built-in components: `spinner` (busy display with elapsed time and thinking state) and `queue` (pending steer/follow-up count, `⏵ N`). The pending-queue *preview* rows stay at the end of the history but no longer pad themselves to the viewport bottom — they simply follow the content.
- **FIXED:** Thinking blocks no longer leave a large gap below the header: the trailing margin is now exactly one blank line (down from ~3 rows including the old status padding), since the spinner no longer renders beneath the buffer.
- **FIXED:** Streaming no longer rebuilds the history status block on every delta: with an empty queue the per-delta status update is a cheap no-op, and the whole-buffer `nvim_win_text_height` scan is gone from the history hot path entirely (the prompt statusline applies the same skip-when-full guard, keeping the spinner tick O(1) even with huge pasted prompts).

- **ADDED:** `quickfix` config option. When pi's `grep` tool finishes, its matches are parsed (`path:line[:col]: text`) and loaded into the quickfix list so you can jump between them with `:cnext` / `:cprev`; the `find` tool's file list can be loaded the same way. The list is titled `pi <tool>: <pattern>` and is never opened automatically (use `:copen`). Defaults: `grep = true`, `find = false`, `glob = false` (`glob` is an alias of `find` for older pi versions).

- **FIXED:** Chat no longer stutters once the history grows large, and large-session replay is faster. The status block (spinner / pending queue / abort hint) recomputed its bottom padding with a whole-buffer `nvim_win_text_height` scan on every streamed token and every spinner tick — O(history size) each, which saturated the main loop on big sessions. The scan is now skipped whenever the conversation provably fills the window.
- **ADDED:** `reload.mode` config option. When pi's `edit`/`write` tool modifies a file that is open in a Neovim buffer, pi2.nvim now automatically reloads it. `"silent"` (default) reloads unmodified buffers quietly; `"notify"` also shows a notification; `false` disables the behavior. Modified buffers (unsaved user changes) are never touched.
- **FIXED:** Opening the resume-session picker (and the continue-session lookup) no longer takes many seconds on projects with large session files. Session listing had regressed to JSON-decoding *every* line of *every* `.jsonl` just to find the latest session name; it now decodes only the rare, small `session_info` lines (cheap substring prefilter) and stops decoding message lines once the first user message is found, keeping listing I/O-bound. The "latest name wins" behavior is unchanged.
- **FIXED:** Loading/resuming a large session is much faster. A `get_messages` response is a single multi-MB JSON line, and the RPC stdout reader rebuilt the growing partial line via repeated string concatenation on every incoming chunk — an O(n²) that took ~2s for a 20MB session (and quadratically worse for bigger ones). Partial lines are now buffered as a list of chunks and concatenated once when complete, cutting the `get_messages` round-trip to a few hundred ms.
- **FIXED:** Loading a large session no longer hangs (and scrolling/paging is responsive again) when using the `render-markdown` engine. render-markdown.nvim re-renders the whole history buffer on every change, and a session replay makes hundreds of buffer edits, so each edit re-parsed the growing buffer (O(n²)) and saturated the event loop — a 23MB session could hang indefinitely. pi now pauses render-markdown for the history buffer while replaying and re-enables it (rendering once) after the edits land.

- **FIXED:** The spinner, pending-queue, and abort-hint status no longer cover history content. The pinned floating overlay introduced on 2026-07-25 is replaced by virtual lines at the end of the buffer, so a freshly sent message and any scrolled-up content are never hidden behind it; when the conversation is shorter than the window the status is padded to sit flush against the bottom edge.
- **FIXED:** The streaming thinking header no longer flickers between one and two wrapped lines. The rolling preview is now end-of-line virtual text (`eol`) instead of `inline`, so it no longer counts toward the header's wrap width.

## 2026-07-26

- **ADDED:** Direct bash mode — prefix the prompt with `!` to run a shell command (e.g. `!ls -la`). Output streams live into a collapsible block in the history, and the result is added to the LLM context on the next prompt. `!!command` excludes output from context. The prompt panel title switches to `bash` (configurable via `panels.prompt.bash_title`) with a distinct foreground color while in bash mode. A single `<Esc>` cancels a running `!` command (`:PiAbortBash` / `pi.abort_bash()`). Bash execution messages replay correctly on session load/switch.
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
