# Testing — the three layers in depth

The repo ships `tests/minimal_init.lua` and a `Makefile` with `test` (hermetic plenary) and `smoke` (headless boot of the user config + open the chat). This file explains each layer, the pitfalls unique to it, and how the `scripts/` templates sidestep them. Pick the cheapest layer that can observe the behavior; escalate only when it cannot.

## Layer 1 — Unit tests (hermetic plenary)

**What it's for:** pure Lua with no UI — stores, parsers, config resolution, pure transforms. Examples in repo: `tests/prompt_history_spec.lua`, `tests/draft_spec.lua`, `tests/render_spec.lua`, `tests/sanity_spec.lua`.

**How it runs:** `make test` → `nvim --headless -u tests/minimal_init.lua -c "...test_directory('tests'...)"`. `minimal_init.lua` prepends plenary + the repo root to `runtimepath` *without* loading the user's config, so it is fast and deterministic. `PLENARY_PATH` overrides the plenary location. Because the repo root is resolved from `minimal_init.lua`'s **own file path**, this layer runs against the current **worktree's** code — it is worktree-safe (G23).

**Rules / pitfalls:**
- `before_each` / `after_each` **must be inside a `describe`**. At the top level they silently no-op *and* the run exits non-zero (`make: Error 1`) with no clear message — the spec just never executes (G14). Always wrap.
- Make stateful modules testable: a `_reset()` to clear singletons and a path-override hook (`_set_path`) so tests use a `vim.fn.tempname()` file, never the real `stdpath`. See `draft.lua` / `prompt_history.lua`.
- Don't name a Makefile variable `NVIM` — nvim injects `$NVIM` (its server socket) into the environment and `?=` won't override it; use `NVIM_BIN` (G15).
- Assert with `assert.are.equal` / `assert.are.same` / `assert.is_nil` / `assert.is_true`. Keep each `it` focused on one behavior.

**Template:** `scripts/unit_spec_template.lua`.

## Layer 2 — Headless end-to-end

**What it's for:** the real plugin loading under the real config, the real chat opening, the RPC backend spawning, buffer/extmark wiring, keymap *registration*, and method-level behavior — everything that doesn't need pixels or real key events.

**How it runs:** `nvim --headless -u ~/.config/nvim/init.lua -l script.lua`. The script drives `require("pi").show{layout="side"}`, `vim.wait(...)` for buffers, mutates buffers, calls chat methods, and exits `cq 0`/`cq 1`. `make smoke` is the minimal version of this (load + assert the two chat buffers exist). **Worktree caveat:** this boots the user's real config, so lazy loads pi from the **main checkout** (`~/.local/share/nvim/lazy/pi2.nvim`), not a feature worktree. To exercise worktree code headless, run the script under `-u tests/minimal_init.lua` instead (path-relative, worktree-safe); see G23.

**Stub the backend** at the top of any script that submits: `chat._agent.send = function(_) end` (get `chat` via `require("pi.sessions.manager").get().chat`). This prevents real model calls *and*, because the stub returns before the RPC send, prevents the pi backend from writing a session transcript — so sessions stay clean.

**Pitfalls unique to headless:**
- **`TextChanged` / `TextChangedI` do NOT fire for programmatic edits in `-l` mode** — not for `nvim_buf_set_lines`, not for `setline`. So a debounced "save on edit" autocmd will never run in the test. Fix: factor the save body into a callable method (e.g. `Prompt:_save_draft()`) that the autocmd calls; the test calls the method directly (G4). The autocmd path is then trusted by construction (it's a one-line call to a unit-covered method).
- **Insert mode does not persist across separate `feedkeys`/`wait` calls.** An `<Up>` expr mapping bound insert-only will look dead because by the time the key is processed the mode reverted to normal. Either feed the whole sequence in one call (`"i<Up>"`) or bind the key in `{ "i", "n" }` (G5). The `<C-p>`/`<C-n>` recall keys use `{ "i", "n" }` precisely so they are robust here *and* for real users who happen to be in normal mode on the prompt.
- **You cannot see rendering.** Treesitter/extmark *counts* are observable (`nvim_buf_get_extmarks`), but whether it *looks right* is not. Visual proof is Layer 3 only (G6).
- **`vim.keycode`/`nvim_replace_termcodes` for a special key, returned from an `<expr>` mapping, inserts raw bytes** (`\x80ku`) as text in this environment. The correct fallback return is the literal angle-bracket string `"<Up>"` (G2). A headless e2e that types into a multi-line prompt and presses `<Up>` on line 2 is exactly the test that catches this.

**Template:** `scripts/headless_e2e_template.lua`.

## Layer 3 — GUI automation (xdotool + wmctrl + maim + RPC)

**What it's for:** the only layer that exercises real keybindings through the terminal emulator, real insert mode, and **visual rendering**. This is where G1, G2, G3, G11, G12 were actually caught. Like `make smoke`, it boots the user config and loads pi from the **main checkout**, so a GUI run does not see a feature worktree's code (G23) — verify worktree changes via unit / headless-`minimal_init`, or point lazy at the worktree first.

**Topology.** A dedicated WezTerm window runs `nvim --listen <SOCK>` on its own i3 workspace (so it tiles full-screen and screenshots are legible — a shared workspace splits the screen and the UI is tiny). `xdotool` sends keys to that window id; `wmctrl` enumerates windows; `maim -i <WID>` screenshots; the nvim **RPC socket** is ground truth (`nvim --server $SOCK --remote-expr 'luaeval("...")'`).

**Why RPC is ground truth, not the screenshot.** The screenshot proves pixels; RPC proves state (cursor line, buffer text, mode, extmark counts, whether render-markdown attached). Assert state over RPC; capture a screenshot as the human-readable artifact and as the only way to confirm visual rendering.

**The harness (`scripts/gui_harness.sh`).** `source` it. Key helpers:
- `q '<lua-expr>'` — evaluate one expression, print it. **Single-quote** the expression in bash.
- `qlua <<'LUA' ... RESULT = ... LUA` — run a multi-line block that sets `RESULT`; printed. Use this whenever the expression has quotes/loops — it writes Lua to a file and `:luafile`s it over RPC, which **avoids shell-quoting hell entirely**. Prefer `qlua`/`runlua` over clever quoting.
- `runlua <<'LUA' ... LUA` — same, side effects only.
- `find_buf <filetype>` — bufnr or `-1`.
- `send <keys>` / `type_text <text>` — xdotool to `$WIN` with inter-key delays.
- `normal` — send `Esc` until mode is normal/visual (G12: the prompt is in insert mode, so any leader/normal key needs this first).
- `shot <name>` — `maim -i $WIN`.
- `check <name> <got> <want>` / `wait_for '<lua-bool>' <tries>`.

**Isolation recipe (do this, every GUI run, or you corrupt the user's data — G17):**
1. Before opening the chat, the user's `~/.local/share/nvim/pi/draft.txt` (if present) is moved to a backup; restored at the end. This stops `restore_once` from pulling a real in-progress draft into the test prompt.
2. Right after the chat opens, redirect the test instance's storage to `/tmp`:
   ```lua
   require("pi.draft")._set_path("/tmp/<run>/draft.txt")
   require("pi.config").options.prompt.history.path = "/tmp/<run>/history.json"
   ```
   The history store is lazy, so setting the path before the first recall/send makes it use the temp file; the user's `prompt_history.json` is never opened by the test instance → no concurrent-write race.
3. Assert at the end: user's draft untouched, user's history has zero test-residue (`grep -c` of your sentinel strings == 0).
4. Delete the temp files; restore the user's workspace (`i3-msg workspace <saved>`).

**Driving real keybindings — the gotchas that matter here:**
- Leader is whatever `vim.g.mapleader` is (in the user's config it is `,`); send it as `comma`. Always `normal` (Esc) first (G12).
- lazy may only *load* the plugin on the first keypress; `wait_for` the `pi-chat-prompt` buffer instead of assuming the toggle completed (G13).
- side layout's WinEnter redirect (G11): to focus history programmatically without a bounce, enter it from the prompt window; or use the real `<C-g>h` binding which the user presses from the prompt anyway.
- `gf` and other normal-mode keys on the history buffer: the history window has `winfixbuf`, so never `:edit` *inside* it in a test; the jump code switches to a non-pi window first.

**Reading a screenshot as proof.** Open the `maim` PNG and confirm the *rendered* form, not the source: headings show as styled text with the `##` concealed; `**bold**`/`*italic*` show as bold/italic with markers gone; list lines show bullets; a fenced block shows a language label + box with the fence concealed; links show an icon + label with the `(...)` gone. If any raw markdown punctuation is visible, rendering did not engage for that region.

**Cleanup (`scripts/gui_cleanup.sh`).** Kills *only* processes whose cmdline contains the test socket string (the test wezterm-gui and nvim), never the user's bare `wezterm-gui` (whose child is a shell) or the user's nvim. It is a **script file on purpose**: an inline `bash -c "…pgrep -f 'wezterm-gui.*pi_gui_test'…"` contains the feature string in its own cmdline and `pgrep -f` matches *itself*, so the cleanup kills its own shell mid-run (G16). The `[p]attern` trick also fails if you put the string on the right-hand side of a variable assignment. Keep cleanup/observation in files, or build the pattern so the literal never appears in the process cmdline.

**Templates:** `scripts/gui_harness.sh`, `scripts/gui_launch.sh`, `scripts/gui_cleanup.sh`.

## Choosing a layer — quick guide

- New pure function / store / parser → **unit**.
- New buffer wiring / extmark logic / config resolution / keymap *exists* → **headless e2e**.
- New keymap *behavior* in insert mode, multi-line editing interaction, anything the user *sees* → **GUI**.
- A change that touches rendering → unit/headless for "extmarks produced + text intact", **GUI screenshot** for "it looks right".

When in doubt, add the cheaper test *and* the GUI screenshot; the screenshot is cheap insurance against the class of bug that only pixels reveal.

## Verification discipline (how to avoid stacking errors)

1. **Lock a baseline first (M0).** Before any feature work, confirm `make test` + `make smoke` are green on a clean checkout and create a feature branch. Every later step re-runs these; a regression fails fast.
2. **Small steps, each verified, each committed.** Build a feature as: pure module → unit test (green) → commit; wire it in → headless e2e (green) → commit; if key/visual → GUI e2e (green) → commit. Each commit is a rollback point.
3. **Milestone gates.** Group steps into milestones; do not start the next milestone until the gate (unit + smoke + relevant e2e, all green) passes. The risky rendering work goes *after* the low-risk input work is locked.
4. **Stub the LLM.** In any e2e that submits a prompt, replace the backend so no real model call and no transcript write happen: `chat._agent.send = function(_) end`. Because the stub short-circuits *before* the RPC send, the pi backend never writes a session file — so sessions are not polluted. (Do **not** `grep` your way to "test sessions" to delete: a match can be inside an *assistant* quote of your test text, i.e. a real session. See gotcha G18.)
5. **Isolate from the user's data.** A test instance shares the user's `stdpath` history/draft files and races with their live pi. Redirect both to `/tmp` (gotcha G17) and assert the user's files stayed untouched.
6. **State exactly what you verified and what you could not**, per `AGENTS.md`.

## How to use the bundled scripts

The `scripts/` directory holds **templates** — copy into `/tmp/<run>/`, fill the few placeholders, run. They are deliberately parameterized (socket path, window id, workspace come from env/files, never hard-coded) so they are reusable across runs and machines.

- `scripts/unit_spec_template.lua` — plenary spec skeleton (note the `describe`-scoping rule, G14).
- `scripts/headless_e2e_template.lua` — headless `-l` skeleton (stub backend, `find_buf`, callable-save pattern for G4).
- `scripts/gui_harness.sh` — `source` this; gives `q`/`qlua`/`runlua`/`find_buf`/`send`/`normal`/`type_text`/`shot`/`check`/`wait_for` over the RPC socket. Lua goes through files (`:luafile`) to dodge shell-quoting hell.
- `scripts/gui_launch.sh` — starts a **dedicated, full-screen** WezTerm+nvim (`--listen`) on its own i3 workspace so screenshots are large; remembers the user's workspace to restore later.
- `scripts/gui_cleanup.sh` — kills *only* the test instance (matched by the socket string in the cmdline), never the user's wezterm/nvim; safe against G16.
- `scripts/makefile.snippet` — the `test`/`smoke` targets already in the repo `Makefile`, for reference when adding targets.

A typical GUI run:

```bash
RUN=/tmp/pi_run; mkdir -p "$RUN"
cp scripts/gui_harness.sh scripts/gui_launch.sh scripts/gui_cleanup.sh "$RUN"/
# (write your run_all.sh in $RUN, sourcing $RUN/gui_harness.sh)
bash "$RUN/gui_launch.sh"     # full-screen isolated instance, prints WIN
bash "$RUN/run_all.sh"        # drives real keybindings, asserts over RPC, screenshots
bash "$RUN/gui_cleanup.sh"    # removes only the test instance
```
