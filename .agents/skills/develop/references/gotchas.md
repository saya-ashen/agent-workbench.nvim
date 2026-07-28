# Gotchas — full 现象 / 根因 / 修法

Each entry is a real defect or trap encountered while adding features to this plugin, with the mechanism and the fix. The quick-reference table below is the index; the full 现象/根因/修法 detail follows. Where a minimal reproduction exists it is included — these reproductions are the fastest way to *see* the trap, and they double as regression checks.

## Quick reference

| # | Fix in one line |
|---|-----------------|
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
| G21 | Restart nvim after editing `lua/pi/**`; lazy never hot-reloads |
| G22 | No whole-buffer APIs (`nvim_win_text_height`, full `get_lines`) on per-event paths; gate behind a cheap provability check |
| G23 | In a worktree, `make smoke`/GUI load the MAIN checkout (lazy path), not your code; verify with `make test` + `-u tests/minimal_init.lua` |
| G24 | No Lua 5.3-only syntax (`&` `\|` `~` `<<` `>>`, `//`, `\u{}`) — stable Neovim's LuaJIT can't parse it; `loop or previous error` is only the secondary symptom |

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
- **现象:** After the first `,ap`, `package.loaded["pi"]` is true but no chat buffers exist yet.
- **根因:** lazy loads the plugin spec on first key use; the mapped toggle may not have executed on that same press.
- **修法:** In tests, `wait_for` the `pi-chat-prompt` buffer; to isolate "is the wiring broken vs. lazy timing", call `require("pi").show({layout="side"})` over RPC and see if buffers appear.

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
- **现象:** After a test, the user's `prompt_history.json` contains the test's sentinel prompts, or their unsent draft is overwritten; worse, two pi instances writing the same file race and clobber each other.
- **根因:** A test instance and the user's live instance share `stdpath("data")/pi/...`.
- **修法:** Redirect the test instance: `require("pi.config").options.prompt.history.path = "/tmp/<run>/history.json"` (set before the first send/recall; the store is lazy) and `require("pi.draft")._set_path("/tmp/<run>/draft.txt")`. Move the user's `draft.txt` aside before the chat opens (so `restore_once` can't pull a real draft into the test prompt) and restore it after. Assert the user's files are untouched and residue-free at the end.

### G18 — You almost delete a real session file
- **现象:** `grep -rl "first prompt" ~/.pi/agent/sessions/` returns files that look like test sessions but are actually large real work sessions.
- **根因:** With the backend stubbed (`chat._agent.send = function(_) end`), the RPC send never happens, so the pi backend writes **no** transcript for test prompts — there are no "test sessions" to delete. The grep hits are real sessions whose *assistant* text quoted the test script you were discussing.
- **修法:** Never delete sessions by grepping for test text. The stub guarantees session cleanliness by construction. Only the lua-side files (history/draft) need cleanup, and those are isolated per G17.

### G19 — New config option "does nothing"
- **现象:** You added a default and read `Config.options.x.y`, but the value is nil / the feature is off.
- **根因:** `config.lua` has three coupled spots — the `---@class` annotation, the field on `pi.Options`, and the `defaults` table. `vim.tbl_deep_extend("force", defaults, opts)` only knows about keys present in `defaults`; missing the annotation misleads users/LuaLS; missing the `pi.Options` field breaks typing.
- **修法:** Edit all three together. Add a unit test that reads the resolved default (see `tests/render_spec.lua`).

### G20 — `get()` returns stale config
- **现象:** A feature reads a config value captured at module load and ignores a later `setup()`.
- **根因:** Caching `local cfg = require("pi.config").options.x` at the top of a module freezes the pre-`setup` deepcopy.
- **修法:** Read `require("pi.config").options` at call time, inside the function that needs it.

### G21 — Fix is green everywhere but the running nvim still shows the bug
- **现象:** Unit + headless + GUI automation are all green, the on-disk code is correct, yet the nvim the user (or you, mid-session) is actually using still behaves the old, broken way.
- **根因:** lazy.nvim reads a plugin's Lua modules into `package.loaded` the first time they are `require`d, and **never** refreshes those tables from disk afterwards. pi is lazy-loaded on first use, so the first `,ap`/command snapshots the modules for the lifetime of that nvim process. If pi was already used in a running nvim before you landed the fix, that process is running the pre-fix code — re-running tests in *that* process will never show the fix. This is exactly how "all tests pass but the user still hits the bug" happens: the test instance is freshly launched (new code), the user's instance is long-lived (old code).
- **修法:** After editing `lua/pi/**`, a **running nvim must be restarted** (or a brand-new nvim opened) to pick up the change. `:Lazy reload pi.nvim` is *not* reliable for this — it re-sources the plugin's start scripts but generally does **not** clear the `package.loaded["pi.*"]` cache, so `require` keeps returning the old tables. When verifying a fix, **always use a freshly launched instance** (`gui_launch.sh` does this); never validate against a session that already has pi loaded, or you will conclude "fixed" while the user's open instance is still old.
- **元教训:** When "tests green but user reports the bug", first ask *when the user's process loaded the module*. If the user is talking to you *through* pi, their pi modules were necessarily required before your fix existed — the bug they see is the snapshot, and the only cure on their side is a restart you cannot perform for them (it would kill the very session you are in).

### G22 — Whole-buffer API call on a per-event hot path stalls large sessions
- **现象:** Once the history grows large (~30k lines), the whole window stutters while the agent streams — prompt typing and cursor movement lag — and large-session replay is slow. Idle redraw is fine; the jank only appears under event load.
- **根因:** `_update_status_extmark` computed its bottom padding with `nvim_win_text_height(win, {})` — an O(whole-buffer) scan, ~17ms at 32k lines — and it ran on **every streamed delta, every tool-output insert, every replay step, and every spinner tick (~80ms)**. Per-event O(n) saturates the main loop (input events queue behind it) and makes replay O(n²). Prime suspect treesitter was innocent: incremental parse stays flat (~0.07ms) regardless of buffer size — measure before blaming it.
- **修法:** Never call whole-buffer APIs (`nvim_win_text_height`, full-buffer `nvim_buf_get_lines`, linear extmark scans) on per-event paths; gate them behind a cheap provability check. Here: visual height ≥ buffer line count always, so once lines fill the window the pad is provably 0 and the scan is skipped (`history.lua` `_update_status_extmark`). Regression-test by stubbing the API to count calls and asserting 0 on the hot path (`tests/history_status_pad_spec.lua`).
- **排查方法:** Headless profile, no UI needed: build a large conversation through the real public API (`on_agent_start` / `on_text_delta` / `on_tool_start` / `on_tool_end`, pumping `vim.wait`), then time individual operations with `vim.uv.hrtime` at several sizes (e.g. 5k / 16k / 32k lines). Scaling exposes the O(n) even when absolute numbers look small at one size.

### G23 — In a worktree, `make smoke` / GUI test the MAIN checkout, not your code
- **现象:** Working in a feature worktree, `make test` reflects your edits but `make smoke` (or a GUI run) still behaves like `main` — a fix "doesn't take", or a smoke check passes/fails for reasons unrelated to your change.
- **根因:** The layers resolve the plugin path differently. `make test` boots `tests/minimal_init.lua`, which computes the repo root from **its own file location** (`debug.getinfo`) and prepends *that* to `runtimepath` — so it loads the worktree's `lua/pi`. But `make smoke` and the GUI harness boot the user's real `~/.config/nvim/init.lua`, and lazy.nvim loads pi from its **installed path** `~/.local/share/nvim/lazy/pi2.nvim` (the main checkout) regardless of your cwd. So those layers exercise main's code, never the worktree's.
- **修法:** During worktree development, verify with the worktree-local layers: `make test` and headless e2e scripts run under `nvim --headless -u tests/minimal_init.lua -l script.lua` (both resolve to the worktree). For smoke/GUI proof of the worktree code, either (a) run it **after merging to `main`**, or (b) temporarily point lazy at the worktree by adding an env-gated `dir` to the pi lazy spec and launching with that env set:
  ```lua
  -- in the user's pi lazy spec (one-time, opt-in)
  dir = vim.env.PI_DEV_DIR or nil,   -- nil => lazy's normal installed path
  ```
  ```bash
  PI_DEV_DIR="$WT_ROOT/<name>" make smoke   # now loads the worktree
  ```
  Never place a worktree **under** `~/.local/share/nvim/lazy/`: lazy treats every directory there as a plugin and would load it as a *second* pi plugin (duplicate modules, double autocmds). Keep worktrees at a sibling root such as `~/.local/share/pi.nvim-worktrees/<name>`.
- **元教训:** The main checkout is a *live plugin path* the running editor depends on; keep it on `main` and do feature work in a worktree so branch switches (yours or a concurrent session's) can't strand uncommitted work on the wrong branch or swap the running editor's code mid-session.

### G24 — Lua 5.3-only syntax parses on your nvim but breaks plugin load on Neovim stable
- **现象:** The plugin loads fine on your machine but on another (Neovim stable, e.g. macOS Homebrew) the first toggle fails with `E5108: ... loop or previous error loading module 'pi.sessions.manager'`. Both machines run the **same commit**.
- **根因:** Two layers. (1) The real error — visible only in `:messages`, above the E5108 — is a *parse* error, e.g. `lua/pi/ui/chat/text.lua:73: ')' expected near '&'`: the code used a Lua 5.3 bitwise operator. Neovim's official stable builds embed LuaJIT, whose parser accepts Lua 5.1 plus a few extensions (`goto`, labels, `continue`) but **not** 5.3-only syntax: bitwise operators (`& | ~ << >>`), integer division `//`, and `\u{...}` escapes. Recent LuaJIT rolling releases (shipped by nvim 0.12+/nightly) added 5.3 bitwise-op *parsing*, so the identical code loads there — the failure is parser-generation-dependent, not commit-dependent, which is why "works on my machine" lied. (2) The message the user sees is a secondary symptom: LuaJIT's `require` plants a sentinel in `package.loaded` before running the module body; when the body throws (a parse error counts), the sentinel stays, and every later `require` of that module in the same session reports `loop or previous error loading module` instead of the real cause. The first failure happens inside lazy.nvim's `setup()` call (reported as `Failed to run 'config' for pi2.nvim` + the real error); the replayed keypress then hits the poisoned module.
- **修法:** Keep everything under `lua/pi/**` parseable by the LuaJIT that Neovim stable ships (Lua 5.1 + goto/continue). Replace bitwise ops with arithmetic or range checks — e.g. the UTF-8 continuation-byte test `(b & 0xc0) == 0x80` is exactly `b >= 0x80 and b <= 0xbf`. Audit a change with:
  ```bash
  grep -rnE '\)&|&\s*0x|[a-z_)]\s*&\s*[0-9a-zA-Z_(]|[<>][<>]\s*[0-9]' lua/   # bitwise ops
  grep -rnE '[0-9a-z_)]\s*//\s*[0-9a-z_(]' lua/                              # integer division
  grep -rn '\\u{' lua/                                                       # 5.3 unicode escapes
  ```
  Belt-and-braces parse check: `find lua -name '*.lua' -exec luac5.1 -p {} +` — but PUC Lua 5.1 also rejects the LuaJIT extensions this repo *does* use (`continue` in `history.lua`, `goto`), so treat those hits as false positives; the authoritative ban list is 5.3-only syntax.
- **排查方法:** `loop or previous error loading module X` is **never** the root cause — it means module X already failed to load earlier in the same nvim session. Look one message up in `:messages` (lazy's `Failed to run 'config' for ...` carries the real error), or restart nvim and `:lua require("pi.sessions.manager")` — a fresh session has no sentinel, so the first require prints the real error. When the same commit behaves differently across machines, compare `:lua =jit and jit.version or _VERSION`: differing LuaJIT vintages explain it.
- **元教训:** This plugin promises "Neovim 0.10+", so its code must parse on the LuaJIT those releases ship — not just on yours. Syntax compatibility is runtime-dependent and stays invisible until someone's stable build fails to load the plugin at all.
