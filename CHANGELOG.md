# Changelog

## 2026-07-26

- **ADDED:** Direct bash mode — prefix the prompt with `!` to run a shell command (e.g. `!ls -la`). Output streams live into a collapsible block in the history, and the result is added to the LLM context on the next prompt. `!!command` excludes output from context. The prompt panel title switches to `bash` (configurable via `panels.prompt.bash_title`) with a distinct foreground color while in bash mode. A single `<Esc>` cancels a running `!` command (`:PiAbortBash` / `pi.abort_bash()`). Bash execution messages replay correctly on session load/switch.

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
