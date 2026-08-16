# Gotchas — full 现象 / 根因 / 修法

Each entry is a real defect or trap encountered while adding features to this plugin, with the mechanism and the fix. The quick-reference table below is the index; the full 现象/根因/修法 detail follows. Where a minimal reproduction exists it is included — these reproductions are the fastest way to *see* the trap, and they double as regression checks.

## Quick reference

| # | Fix in one line |
| --- | ----------------- |
| G27 | macOS: `screencapture` errors and window lists hide other apps' windows ⇒ grant **Screen Recording** to the terminal, restart it; harness degrades loudly, never silently |
| G28 | macOS: since macOS 14, **background** activation (`set frontmost`, `NSRunningApplication.activate`) is silently ignored — worse under tmux, which detaches your process tree from the GUI app ⇒ inject input as **terminal bytes** (`wezterm cli send-text --no-paste`), never AppleScript keystrokes |
| G29 | macOS: find the test wezterm-gui by the socket string in **its own** cmdline — it daemonizes (ppid=1) and its argv *also* matches `nvim.*--listen` patterns |
| G30 | macOS: **no API captures windows on non-active Spaces** (`screencapture -l` “could not create image”, SCK −3811) ⇒ the test instance **self-fullscreens** at launch (GUI-side `gui-startup` + delayed `toggle_fullscreen`) — the one Space switch that always works |
| G1 | Defer buffer edits in `<expr>` mappings with `vim.schedule` |
| G2 | Return literal `"<Up>"` from `<expr>`, never `vim.keycode` |
| G3 | Compare buffer text to last-applied, don't use a timing flag |
| G4 | Headless: call save method directly, `TextChanged` won't fire |
| G5 | Headless: feed `"i<Up>"` in one call, or bind `{ "i", "n" }` |
| G6 | Visual correctness needs a GUI screenshot, headless can't prove it |
| G7 | Builtin renderer is `conceallevel=0`; use render-markdown for chrome |
| G8 | render-markdown auto-attach needs `plugin/` sourced (lazy does this) |
| G9 | Headless: force `render-markdown.render({ buf = buf })` |
| G10 | markview ignores `buftype=nofile`; prefer render-markdown |
| G11 | Enter history window from prompt to avoid WinEnter redirect |
| G12 | Send `Esc` before normal/leader keys (prompt auto-inserts) |
| G13 | lazy loads on first key; `wait_for` the buffer |
| G14 | `before_each`/`after_each` must be inside a `describe` |
| G15 | Use `NVIM_BIN` not `NVIM` in Makefile |
| G16 | Put cleanup in script files, not inline `bash -c` |
| G17 | Redirect history/draft paths to `/tmp` in tests |
| G18 | Never delete sessions by grep; stubbed send writes no transcript |
| G19 | Edit all three config spots together |
| G20 | Read `config.options` at call time, never cache at module load |
| G21 | Restart nvim after editing `lua/agent-workbench/**`; lazy never hot-reloads |
| G22 | No whole-buffer APIs (`nvim_win_text_height`, full `get_lines`) on per-event paths; gate behind a cheap provability check |
| G23 | In a worktree, GUI loads MAIN checkout unless redirected; `make test`/`make smoke` use current checkout |
| G24 | No Lua 5.3-only syntax (`&` `\|` `~` `<<` `>>`, `//`, `\u{}`) — stable Neovim's LuaJIT can't parse it; `loop or previous error` is only the secondary symptom |
| G25 | Validate failure-counting grep patterns against known-failing output first; prefer plenary's literal `Failed :`/`Errors :` summary lines over regexes across colored output |
| G26 | uv callbacks (`vim.system`, timers) are fast events — `vim.schedule` any editor work; `repeat = 0` is one-shot; hold timer objects or they are GC'd |

### G27 — macOS: Screen Recording is a hard gate for screenshots AND window discovery

- **现象:** On a macOS GUI run, `gui_launch.sh` finds the wezterm-gui pid but **no CGWindowID**; `screencapture` fails with `could not create image`; a direct `CGWindowListCopyWindowInfo` probe returns an empty/`{}` list even though several apps have visible windows.
- **根因:** macOS TCC. Without the **Screen Recording** permission, (1) `screencapture` cannot read display contents, and (2) `CGWindowListCopyWindowInfo` silently returns only the *caller's own* windows — other apps' windows simply don't appear, no error. The permission is granted per **host terminal app** (the app that owns your shell — WezTerm/iTerm/Terminal), and a grant only takes effect after that app **restarts**. Accessibility (needed for keystrokes) is a separate toggle — one can be granted while the other is denied.
- **修法:** System Settings → Privacy & Security → Screen Recording → enable the terminal app → **restart the terminal** (this kills sessions inside it, including a pi agent running there — plan around that). Probe before a run:

  ```bash
  screencapture -x -R0,0,50,50 /tmp/probe.png   # errors when denied
  ```

  The harness must degrade **loudly**: launch warns that `shot` will be skipped, `shot` SKIP/FAILs with the remedy instead of passing, and a tiny-file sanity check catches the all-one-color PNG a denied/buggy capture can still produce. A screenshot that silently never happened is the G25 class of fake-green.
- **排查方法:** Window-id discovery must not use the JXA ObjC bridge: on macOS 26 `ObjC.import("CoreGraphics")` fails to bind `CGWindowListCopyWindowInfo` — the result's `.count` is `undefined`, so filters silently match nothing (a `{}` owners dict that *looks* like the TCC denial). `gui_launch.sh` embeds a tiny Swift helper instead; `swift file.swift <pid>` needs no bridge metadata and returns the real CGWindowIDs.

### G28 — macOS: background activation is ignored; inject bytes, don't fight for focus

- **现象:** An AppleScript-driven run lands its keys in the user's fullscreen WezTerm instead of the test window. `set frontmost` / Swift `NSRunningApplication.activate` print success yet the frontmost pid bounces straight back to the user's app. Works when the agent runs directly in a terminal; breaks the moment it runs **inside tmux**.
- **根因:** Since macOS 14, activation requests from **background** processes are silently dropped. A tmux server daemonizes (reparented to launchd), so your shell is no longer a descendant of any GUI app and every activate/set-frontmost is a no-op. A fullscreen app's Space additionally re-grabs focus. Keystrokes via System Events only ever reach the frontmost app, so without reliable activation the whole approach collapses.
- **修法:** Don't use OS key events at all. Write the byte stream a keypress would produce (Esc=`\x1b`, Up=`\x1b[A`, ctrl+g=`\x07`) straight into the test pane's pty: `WEZTERM_UNIX_SOCKET=~/.local/share/wezterm/gui-sock-<pid> wezterm cli send-text --pane-id <N> --no-paste`. nvim consumes bytes, so real keybindings are exercised identically — but delivery is focus-independent and needs NO Accessibility permission. `--no-paste` is mandatory (nvim enables bracketed paste; a paste-wrapped leader sequence inserts as text instead of firing mappings). What this deliberately does not cover is WezTerm's key→byte translation, which is not our code. Caveat: byte injection produces no OS focus events, so layout focus/insert autocmds don't fire — `type_text` focuses the prompt + `startinsert` via RPC first.

### G29 — macOS: "parent of nvim" does not find the test wezterm-gui

- **现象:** `WTPID=$(ps -o ppid= -p $NVPID)` yields `1` (launchd), or the recorded wezterm pid is dead minutes later; `ensure_focus` then errors `-1719` (no such process) and keystrokes scatter to whatever is frontmost.
- **根因:** Two macOS facts. (1) `wezterm start -- ... nvim --listen $SOCK` **daemonizes**: the CLI process exits and the real wezterm-gui is reparented to launchd, so no ppid chain connects nvim to the GUI you launched. (2) The daemonized wezterm-gui's own argv contains the whole payload command (`... start --always-new-process -- nvim --listen /tmp/....sock`), so `pgrep -f "nvim.*--listen.*$SOCK"` matches **wezterm-gui itself**, not (only) nvim.
- **修法:** Discover by the socket string in the GUI's **own** cmdline: `pgrep -f "wezterm-gui.*$SOCK"` — exactly the pattern cleanup already uses. The same daemonization is why cleanup must kill by *both* the recorded pid and the socket pattern (the recorded pid can be the exited CLI).

### G30 — macOS: off-Space windows are uncapturable; the test instance fullscreens itself

- **现象:** The CGWindowID of the test window is known, yet `screencapture -x -o -l <id>` fails with `could not create image from window`. A ScreenCaptureKit attempt (`SCContentFilter(desktopIndependentWindow:)`) finds the window (`isOnScreen=false`) but errors `−3811 capture failed`.
- **根因:** macOS has **no API to pixel-capture a window on a non-active Space** — CGWindowImage, `screencapture -l`, and SCK all refuse. The test window lands on a desktop Space while the user's fullscreen WezTerm owns the active Space; and per G28 you cannot switch Spaces from a background CLI (Mission Control ctrl+←/→ may also be eaten by tmux/WezTerm or disabled). AX can't even enumerate off-Space windows, so AXFullScreen is out too.
- **修法:** The only Space switch that always works is one a **GUI performs on its own window**. Launch the test wezterm with a generated `--config-file` whose `gui-startup` hook does `mux.spawn_window(cmd)` then, after ~1s (an immediate call only maximizes — verified), `gui_window:toggle_fullscreen()` with `native_macos_fullscreen_mode = true`. The fullscreen transition moves the window to a new Space AND switches the view — making it capturable and legible. Cleanup kills the GUI; its Space vanishes and the view returns by itself. (Note: SCK from a CLI also needs `let _ = NSApplication.shared` first, or `SCContentFilter` aborts on `CGS_REQUIRE_INIT`.)

---

### G1 — Buffer edit inside an `<expr>` mapping is silently dropped

- **现象:** An `<expr>` mapping calls a function that does `nvim_buf_set_lines(...)`; the buffer does not change, no error.
- **根因:** Neovim forbids mutating the buffer while an `<expr>` mapping's expression is being evaluated; the change is dropped silently.
- **修法:** Defer the mutation: set a flag, return `""` from the expr, and do the `set_lines` inside `vim.schedule`. The plain (non-expr) mappings are unaffected by the schedule, so it is safe to use unconditionally.

### G2 — `<expr>` fallback inserts raw bytes (`<80>ku`) as text

- **现象:** An insert-mode `<expr>` mapping that wants to *pass through* `<Up>` returns `vim.keycode("<Up>")` (or `nvim_replace_termcodes("<Up>", true, false, true)`); instead of moving the cursor, the literal bytes `\x80ku` get inserted into the buffer.
- **根因:** Inside an `<expr>` mapping, special keys must be returned as the **literal angle-bracket notation** string. The internal keycode bytes are treated as ordinary text.
- **修法:** Return `"<Up>"` / `"<Down>"` as plain strings. Verified by minimal repro (run headless, `-u NONE`):

  ```lua
  -- variant that inserts garbage:  return vim.keycode("<Up>")
  -- variant that works:           return "<Up>"
  ```

  A GUI/headless test that puts the cursor on line 2 of a multi-line prompt and presses `<Up>` (which must *move*, not recall) is the regression check: assert the buffer text is unchanged.

### G3 — History recall works once, then can't walk further back

- **现象:** First `<C-p>` shows the newest entry; a second `<C-p>` shows the newest entry *again* instead of the older one. Navigation state reads `navigating() == false` right after the first recall.
- **根因:** `TextChangedI` is a **deferred** event. The naive guard is a boolean `_applying_history` set true around the programmatic edit and cleared in a `vim.schedule` right after `set_lines`. But the deferred `TextChangedI` fires *after* that clearing schedule, so the "manual-edit resets navigation" autocmd sees the flag already false and wipes navigation. (Caught only at the GUI layer; unit + headless passed because they don't fire the deferred event the same way.)
- **修法:** Don't use a timing flag. Record the exact text you wrote (`self._last_applied_prompt = text`); in the reset autocmd, compare the current buffer text to it — equal ⇒ programmatic recall (skip reset), different ⇒ genuine manual edit (reset). This is independent of schedule/deferred ordering.

### G4 — Headless e2e: the `TextChanged` save hook never fires

- **现象:** A debounced "persist on edit" autocmd works interactively but the headless `-l` test sees the file unchanged after `nvim_buf_set_lines`.
- **根因:** In `-l` script mode, programmatic edits (`nvim_buf_set_lines`, `setline`) do **not** emit `TextChanged`/`TextChangedI` at all.
- **修法:** Factor the save body into a method (e.g. `Prompt:_save_draft()`); the autocmd becomes a one-line debounced call to it; the test calls the method directly. The autocmd path is then trusted by construction. (Real interactive typing *does* fire `TextChangedI`, so the autocmd is correct for production.)

### G5 — Headless e2e: an insert-only `<Up>` expr key "does nothing"

- **现象:** `feedkeys("<Up>")` then `wait` leaves the buffer unchanged; diagnostics show mode `n` at the moment the key is processed.
- **根因:** Insert mode does not persist across separate `feedkeys`/`wait` calls in headless; by the time the key is handled the mode reverted to normal, and the mapping is insert-only.
- **修法:** Feed the whole sequence in one call (`vim.api.nvim_feedkeys("i" .. vim.keycode("<Up>"), "x", false)`), or bind the key in `{ "i", "n" }` so it works in both modes (the recall keys do this).

### G6 — "I can't verify the markdown looks right" headless

- **现象:** Extmark counts are non-zero, text is intact, no errors — but you cannot tell if headings/bold/code chrome actually render.
- **根因:** Headless has no display; rendering correctness is a visual property.
- **修法:** A GUI `maim` screenshot is the *only* proof. Open the PNG and confirm the *rendered* form (markers concealed, chrome drawn). See `testing.md` "Reading a screenshot as proof".

### G7 — Builtin code-block chrome looks redundant / breaks tool output

- **现象:** Adding a language label + box around fenced blocks in the builtin renderer either shows the box *and* the raw ` ```lua ` line (redundant) or, if you conceal the fence, mangles tool output that contains fence-like lines.
- **根因:** The history window is intentionally `conceallevel=0` (so tool output stays verbatim). Pretty chrome needs conceal, which directly conflicts; and you can't visually verify the result headless.
- **修法:** Don't add conceal-based chrome to builtin. Deliver rich chrome via the opt-in `render-markdown` engine (`render.engine = "render-markdown"`), which already draws language labels + boxes correctly (confirmed by screenshot).

### G8 — render-markdown "doesn't attach" in a spike

- **现象:** After `require("render-markdown").setup{ file_types = {"pi-chat-history"} }`, `manager.attached(buf)` is false.
- **根因:** Auto-attach is registered by `plugin/render-markdown.lua` calling `manager.init()` (a global `FileType` autocmd). lazy.nvim sources `plugin/` on load; a runtime `vim.opt.runtimepath:prepend(...)` does **not**, so the autocmd is never created.
- **修法:** In a spike, call `require("render-markdown.core.manager").init()` explicitly after setup. In production (lazy install) it just works.

### G9 — render-markdown renders nothing on injected text, headless

- **现象:** Buffer attached, `enabled` true, window present, but after injecting markdown and waiting, the render-markdown namespace has 0 extmarks; a manual forced render produces them.
- **根因:** render-markdown's render is an async treesitter parse driven by its event hooks; headless's passive `TextChanged` path doesn't drive it the way an interactive event loop does.
- **修法:** In tests, force `require("render-markdown").render({ buf = buf, event = "Api" })` (public API). Interactively, its own `TextChanged`/`CursorMoved` hooks handle streaming — that is the mechanism codecompanion.nvim relies on too. (Don't add a competing pi-owned debounced re-render: it races with render-markdown's async pass and can *clear* a forced render in headless.)

### G10 — markview ignores the history buffer

- **现象:** markview attaches nowhere on the history buffer by default.
- **根因:** The history buffer is `buftype=nofile`, and markview's default `preview.ignore_buftypes = {"nofile"}` excludes it; you must clear that list *and* add the filetype. render-markdown's `buftype.nofile` config works out of the box.
- **修法:** Prefer render-markdown for this integration (smaller config surface, chat-streaming precedent, nofile-ready).

### G11 — Programmatic focus of the history window bounces to the prompt

- **现象:** `nvim_set_current_win(history_win)` from an editor window ends with focus on the prompt; in a test, a subsequent key lands in the prompt.
- **根因:** Side layout's `WinEnter` autocmd on the history buffer redirects focus to the prompt when the *previous* window was not the prompt.
- **修法:** Enter history from the prompt window (real users do this via the focus binding), or expect/await the redirect. The `goto_path_at_cursor` flow avoids the issue by switching to a non-pi window *before* `:edit`.

### G12 — A leader/normal key "types a comma" into the prompt

- **现象:** Sending `,ap` (or `gf`) while the chat is open inserts a literal comma / does nothing useful.
- **根因:** The prompt auto-enters insert mode on focus; in insert mode the leader sequence is text.
- **修法:** Send `Esc` first (the harness `normal` helper polls mode until normal/visual). Applies to real users and to xdotool alike.

### G13 — First keypress only loads the plugin; toggle seems dead

- **现象:** After the first `,ap`, `package.loaded["agent-workbench"]` is true but no chat buffers exist yet.
- **根因:** lazy loads the plugin spec on first key use; the mapped toggle may not have executed on that same press.
- **修法:** In tests, `wait_for` the `pi-chat-prompt` buffer; to isolate "is the wiring broken vs. lazy timing", call `require("agent-workbench").show({layout="side"})` over RPC and see if buffers appear.

### G14 — A plenary spec silently never runs; `make test` exits 1

- **现象:** A new `*_spec.lua` is scheduled but produces no `Success` lines, and `make` reports `Error 1` with no failing assertion shown.
- **根因:** `before_each` / `after_each` placed at the **top level** (outside any `describe`) no-op, and plenary fails the file.
- **修法:** Always nest them inside a `describe("...", function() ... end)`. Wrap the whole file in one outer `describe` if you need shared setup.

### G15 — `make test` runs the wrong nvim / errors oddly

- **现象:** The `test` target invokes a path like `/run/user/1000/nvim.<pid>.0` instead of the nvim binary.
- **根因:** nvim injects `$NVIM` (its server socket) into child processes; a Makefile `NVIM ?= nvim` does not override an already-set env var.
- **修法:** Name the variable `NVIM_BIN`.

### G16 — Your cleanup `pgrep`/`pkill` kills its own shell

- **现象:** A one-liner like `bash -c "… pgrep -f 'wezterm-gui.*pi_gui_test' …"` matches pid of *that bash* (its cmdline contains the feature string), so `kill $()` terminates the cleanup mid-run; later steps (rm, restore) never execute.
- **根因:** `pgrep -f` matches against full cmdlines, including the shell running the pattern. The `[p]attern` trick fails if the literal string also appears elsewhere in the cmdline (e.g. on the right side of `F='…pi_gui_test…'`).
- **修法:** Put cleanup and observation in **script files** (their cmdline is `bash /path/cleanup.sh`, no feature string). Match test processes by a string that only test processes contain (the socket path), and never embed that string in the observation command's text.

### G17 — Test run corrupts the user's prompt history / draft

- **现象:** After a test, the user's `prompt_history.json` contains the test's sentinel prompts, or their unsent draft is overwritten.
- **根因:** A test instance still shares `stdpath("data")/pi/...` with the user's live instance. Production drafts isolate workspaces and processes, but a test can claim a stale real draft when it opens.
- **修法:** Before opening chat, redirect the draft with `require("agent-workbench.draft")._set_path("/tmp/<run>/draft.txt")`. Also set `require("agent-workbench.config").options.prompt.history.path = "/tmp/<run>/history.json"` before the first send/recall; the history store is lazy. Assert the user's files are untouched and residue-free at the end.

### G18 — You almost delete a real session file

- **现象:** `grep -rl "first prompt" ~/.pi/agent/sessions/` returns files that look like test sessions but are actually large real work sessions.
- **根因:** With the backend stubbed (`chat._agent.send = function(_) return true end`), the RPC send never happens, so the pi backend writes **no** transcript for test prompts — there are no "test sessions" to delete. The grep hits are real sessions whose *assistant* text quoted the test script you were discussing.
- **修法:** Never delete sessions by grepping for test text. The stub guarantees session cleanliness by construction. Only the lua-side files (history/draft) need cleanup, and those are isolated per G17.

### G19 — New config option "does nothing"

- **现象:** You added a default and read `Config.options.x.y`, but the value is nil / the feature is off.
- **根因:** `config.lua` has three coupled spots — the `---@class` annotation, the field on `pi.Options`, and the `defaults` table. `vim.tbl_deep_extend("force", defaults, opts)` only knows about keys present in `defaults`; missing the annotation misleads users/LuaLS; missing the `pi.Options` field breaks typing.
- **修法:** Edit all three together. Add a unit test that reads the resolved default (see `tests/render_spec.lua`).

### G20 — `get()` returns stale config

- **现象:** A feature reads a config value captured at module load and ignores a later `setup()`.
- **根因:** Caching `local cfg = require("agent-workbench.config").options.x` at the top of a module freezes the pre-`setup` deepcopy.
- **修法:** Read `require("agent-workbench.config").options` at call time, inside the function that needs it.

### G21 — Fix is green everywhere but the running nvim still shows the bug

- **现象:** Unit + headless + GUI automation are all green, the on-disk code is correct, yet the nvim the user (or you, mid-session) is actually using still behaves the old, broken way.
- **根因:** lazy.nvim reads a plugin's Lua modules into `package.loaded` the first time they are `require`d, and **never** refreshes those tables from disk afterwards. pi is lazy-loaded on first use, so the first `,ap`/command snapshots the modules for the lifetime of that nvim process. If pi was already used in a running nvim before you landed the fix, that process is running the pre-fix code — re-running tests in *that* process will never show the fix. This is exactly how "all tests pass but the user still hits the bug" happens: the test instance is freshly launched (new code), the user's instance is long-lived (old code).
- **修法:** After editing `lua/agent-workbench/**`, a **running nvim must be restarted** (or a brand-new nvim opened) to pick up the change. `:Lazy reload agent-workbench.nvim` is *not* reliable for this — it re-sources the plugin's start scripts but generally does **not** clear the `package.loaded["agent-workbench.*"]` cache, so `require` keeps returning the old tables. When verifying a fix, **always use a freshly launched instance** (`gui_launch.sh` does this); never validate against a session that already has Agent Workbench loaded, or you will conclude "fixed" while the user's open instance is still old.
- **元教训:** When "tests green but user reports the bug", first ask *when the user's process loaded the module*. If the user is talking to you *through* pi, their pi modules were necessarily required before your fix existed — the bug they see is the snapshot, and the only cure on their side is a restart you cannot perform for them (it would kill the very session you are in).

### G22 — Whole-buffer API call on a per-event hot path stalls large sessions

- **现象:** Once the history grows large (~30k lines), the whole window stutters while the agent streams — prompt typing and cursor movement lag — and large-session replay is slow. Idle redraw is fine; the jank only appears under event load.
- **根因:** `_update_status_extmark` computed its bottom padding with `nvim_win_text_height(win, {})` — an O(whole-buffer) scan, ~17ms at 32k lines — and it ran on **every streamed delta, every tool-output insert, every replay step, and every spinner tick (~80ms)**. Per-event O(n) saturates the main loop (input events queue behind it) and makes replay O(n²). Prime suspect treesitter was innocent: incremental parse stays flat (~0.07ms) regardless of buffer size — measure before blaming it.
- **修法:** Never call whole-buffer APIs (`nvim_win_text_height`, full-buffer `nvim_buf_get_lines`, linear extmark scans) on per-event paths; gate them behind a cheap provability check. Here: visual height ≥ buffer line count always, so once lines fill the window the pad is provably 0 and the scan is skipped (`history.lua` `_update_status_extmark`). Regression-test by stubbing the API to count calls and asserting 0 on the hot path (`tests/history_status_pad_spec.lua`).
- **排查方法:** Headless profile, no UI needed: build a large conversation through the real public API (`on_agent_start` / `on_text_delta` / `on_tool_start` / `on_tool_end`, pumping `vim.wait`), then time individual operations with `vim.uv.hrtime` at several sizes (e.g. 5k / 16k / 32k lines). Scaling exposes the O(n) even when absolute numbers look small at one size.

### G23 — In a worktree, GUI automation tests the MAIN checkout unless redirected

- **现象:** Working in a feature worktree, unit/smoke tests reflect edits but a GUI run still behaves like `main` — a fix "doesn't take", or GUI proof reflects unrelated code.
- **根因:** `make test` and `make smoke` boot `tests/minimal_init.lua`, which resolves the repo root from its own file location and prepends that checkout to `runtimepath`. The GUI harness boots the user's real `~/.config/nvim/init.lua`, so lazy.nvim loads pi from installed path `~/.local/share/nvim/lazy/agent-workbench.nvim` regardless of cwd.
- **修法:** Use `make test`, `make smoke`, and headless e2e under `nvim --headless -u tests/minimal_init.lua -l script.lua` during worktree development. For GUI proof, run after merging to `main`, or point lazy at the worktree with the existing `PI_DEV_DIR` gate:

  ```bash
  PI_DEV_DIR="$WT_ROOT/<name>" nvim
  ```

  Never place a worktree **under** `~/.local/share/nvim/lazy/`: lazy treats every directory there as a plugin and would load it as a *second* pi plugin. Keep worktrees at a sibling root such as `~/.local/share/agent-workbench.nvim-worktrees/<name>`.
- **元教训:** The main checkout is a *live plugin path* the running editor depends on; keep it on `main` and do feature work in a worktree so branch switches cannot swap the running editor's code mid-session.

### G24 — Lua 5.3-only syntax parses on your nvim but breaks plugin load on Neovim stable

- **现象:** The plugin loads fine on your machine but on another (Neovim stable, e.g. macOS Homebrew) the first toggle fails with `E5108: ... loop or previous error loading module 'pi.sessions.manager'`. Both machines run the **same commit**.
- **根因:** Two layers. (1) The real error — visible only in `:messages`, above the E5108 — is a *parse* error, e.g. `lua/agent-workbench/ui/chat/text.lua:73: ')' expected near '&'`: the code used a Lua 5.3 bitwise operator. Neovim's official stable builds embed LuaJIT, whose parser accepts Lua 5.1 plus a few extensions (`goto`, labels, `continue`) but **not** 5.3-only syntax: bitwise operators (`& | ~ << >>`), integer division `//`, and `\u{...}` escapes. Recent LuaJIT rolling releases (shipped by nvim 0.12+/nightly) added 5.3 bitwise-op *parsing*, so the identical code loads there — the failure is parser-generation-dependent, not commit-dependent, which is why "works on my machine" lied. (2) The message the user sees is a secondary symptom: LuaJIT's `require` plants a sentinel in `package.loaded` before running the module body; when the body throws (a parse error counts), the sentinel stays, and every later `require` of that module in the same session reports `loop or previous error loading module` instead of the real cause. The first failure happens inside lazy.nvim's `setup()` call (reported as `Failed to run 'config' for pi2.nvim` + the real error); the replayed keypress then hits the poisoned module.
- **修法:** Keep everything under `lua/agent-workbench/**` parseable by the LuaJIT that Neovim stable ships (Lua 5.1 + goto/continue). Replace bitwise ops with arithmetic or range checks — e.g. the UTF-8 continuation-byte test `(b & 0xc0) == 0x80` is exactly `b >= 0x80 and b <= 0xbf`. Audit a change with:

  ```bash
  grep -rnE '\)&|&\s*0x|[a-z_)]\s*&\s*[0-9a-zA-Z_(]|[<>][<>]\s*[0-9]' lua/   # bitwise ops
  grep -rnE '[0-9a-z_)]\s*//\s*[0-9a-z_(]' lua/                              # integer division
  grep -rn '\\u{' lua/                                                       # 5.3 unicode escapes
  ```

  Belt-and-braces parse check: `find lua -name '*.lua' -exec luac5.1 -p {} +` — but PUC Lua 5.1 also rejects the LuaJIT extensions this repo *does* use (`continue` in `history.lua`, `goto`), so treat those hits as false positives; the authoritative ban list is 5.3-only syntax.
- **排查方法:** `loop or previous error loading module X` is **never** the root cause — it means module X already failed to load earlier in the same nvim session. Look one message up in `:messages` (lazy's `Failed to run 'config' for ...` carries the real error), or restart nvim and `:lua require("agent-workbench.sessions.manager")` — a fresh session has no sentinel, so the first require prints the real error. When the same commit behaves differently across machines, compare `:lua =jit and jit.version or _VERSION`: differing LuaJIT vintages explain it.
- **元教训:** This plugin promises "Neovim 0.10+", so its code must parse on the LuaJIT those releases ship — not just on yours. Syntax compatibility is runtime-dependent and stays invisible until someone's stable build fails to load the plugin at all.

### G25 — A failure-counting grep that never matches reports "all green" on a failing suite

- **现象:** A verification loop reported `make test` green three runs in a row; the suite actually contained a failing spec. The failing test was merged into main and needed a follow-up fix commit (`33d26fa`, after the #32 stream-coalescing merge).
- **根因:** Plenary's colored failure line is `Fail\x1b[0m\t||` — between `Fail` and `||` sit the 4-byte ANSI reset **and** a tab. The checker's pattern `Fail.\{0,3\}\|\|` allowed at most 3 characters in that gap, so it matched nothing on *any* run — including runs with real failures. Counting "zero matches" as success without ever proving the pattern matches a failure inverted the check into unconditional success.
- **修法:** Before trusting any pattern that counts failures, prove it against a synthetic failure: `printf 'Fail\x1b[0m\t||\tx\n' | grep -c '<pattern>'` must print 1. Better, don't regex across colored output at all — assert on the literal summary lines plenary always prints: `grep -E 'Failed : |Errors : ' out.txt | grep -v $'\t0'` must be empty, and the `Success\x1b[0m` count must equal the known assertion total. A check that cannot fail is worse than no check: it manufactures confidence.
- **元教训:** Verification code is code and needs its own test. When a gate reports success, the first question is "have I seen it fail?" — if not, the gate is untested.

### G26 — libuv callbacks are fast events; timers are one-shot by default and GC-fragile

- **现象:** Inside a `vim.system(..., callback)` or `vim.uv.new_timer()` callback, editor calls throw `E5560: nvim_buf_get_lines must not be called in a lua loop callback`. Separately: a periodic flush fires exactly once, or silently stops working after a while.
- **根因:** Three distinct traps, all from the libuv layer. (1) uv callbacks run in **fast-event context**: most `vim.api`/`vim.fn` calls are forbidden there (pure-Lua state mutation is fine). (2) `timer:start(timeout, repeat, cb)` with `repeat = 0` means *fire once* — a periodic tick needs `repeat > 0`. (3) uv handles are held weakly from Lua: a timer referenced only by a local that goes out of scope is garbage-collected, and its callbacks stop with no error.
- **修法:** Wrap callback bodies that touch the editor in `vim.schedule(function() ... end)` (or `vim.schedule_wrap`); keep pure-Lua bookkeeping in the fast path if you want to. Store timer objects in module-level locals or class fields for as long as they must run, and `stop()`/`close()` them explicitly on teardown. Pass the interval as the second `start()` argument for repeating timers. These constraints shaped the 30ms coalescing flush in `history.lua` (#32) and the deferred-spawn async refresh in `pi/cache/files.lua` (#34).
