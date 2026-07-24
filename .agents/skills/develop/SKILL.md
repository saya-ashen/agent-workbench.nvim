---
name: develop
description: Use when developing, testing, debugging, or adding/changing features in this pi.nvim plugin. Covers the three-layer test stack (hermetic plenary unit tests, headless end-to-end, and xdotool+wmctrl+maim GUI automation over the nvim RPC socket), the non-obvious Neovim-Lua gotchas that bite this codebase, the standard places a new feature lands, and the verification discipline. Read this before touching lua/pi/** or tests/**.
---

# Developing & testing pi.nvim

This skill is the *operational* companion to the repo's `AGENTS.md`. `AGENTS.md` is the project charter (architecture, conventions, style); this skill is the hands-on playbook for **building a feature and proving it works** — including the automated test harness that did not exist when the charter was written.

> Scope: everything below assumes you are working inside this repo (`lua/pi/**`, `tests/**`, the `Makefile`). For user-facing behavior changes, also update `README.md` in the same change (per `AGENTS.md`).

## The one rule: verification is layered, and each layer has a job

Never claim a change works from reading code or a diff. Prove it at the cheapest layer that can see the behavior, and escalate only when a layer genuinely cannot:

| Layer | Command | Sees | Cannot see |
| --- | --- | --- | --- |
| Unit (hermetic plenary) | `make test` | pure-Lua logic (stores, parsers, config resolution) | buffers, windows, keys, rendering |
| Headless e2e | `make smoke` + `nvim --headless -u ~/.config/nvim/init.lua -l script.lua` | real plugin load, real chat open, RPC backend, buffer/extmark wiring | **visual rendering**, real key events, real `TextChanged` |
| GUI automation | `scripts/gui_launch.sh` + `scripts/gui_harness.sh` | real keybindings, real insert mode, **visual rendering** (maim screenshots) | (this is the top — but it is slow and touches a live X session) |

A change to a pure module → unit test. A change to buffer/extmark wiring → headless e2e. A change to keymaps, insert-mode behavior, or anything visual → GUI automation. **Most real bugs in this codebase only surface at the GUI layer** (see the gotchas: several were invisible to unit + headless).

The repo already has the harness wired: `tests/minimal_init.lua` + `Makefile` targets `test` and `smoke`. Templates for adding to each layer live in `scripts/` and are explained in `references/testing.md`.

## Verification discipline (how to avoid stacking errors)

1. **Lock a baseline first (M0).** Before any feature work, confirm `make test` + `make smoke` are green on a clean checkout and create a feature branch. Every later step re-runs these; a regression fails fast.
2. **Small steps, each verified, each committed.** Build a feature as: pure module → unit test (green) → commit; wire it in → headless e2e (green) → commit; if key/visual → GUI e2e (green) → commit. Each commit is a rollback point.
3. **Milestone gates.** Group steps into milestones; do not start the next milestone until the gate (unit + smoke + relevant e2e, all green) passes. The risky rendering work goes *after* the low-risk input work is locked.
4. **Stub the LLM.** In any e2e that submits a prompt, replace the backend so no real model call and no transcript write happen: `chat._agent.send = function(_) end`. Because the stub short-circuits *before* the RPC send, the pi backend never writes a session file — so sessions are not polluted. (Do **not** `grep` your way to "test sessions" to delete: a match can be inside an *assistant* quote of your test text, i.e. a real session. See gotcha G18.)
5. **Isolate from the user's data.** A test instance shares the user's `stdpath` history/draft files and races with their live pi. Redirect both to `/tmp` (gotcha G17) and assert the user's files stayed untouched.
6. **State exactly what you verified and what you could not**, per `AGENTS.md`.

## Standard places a new feature lands

A feature that the user configures and triggers from the chat touches a predictable set of files. Use this as a checklist (details + the *why* in `references/architecture.md`):

- **Config knob** → `lua/pi/config.lua`, in **three** spots: the `---@class` annotation, the field on `pi.Options`, and the `defaults` table (gotcha: missing any one silently misbehaves).
- **Pure logic** → a new `lua/pi/<name>.lua` returning one table; private fields/methods prefixed `_`; a process-wide singleton via a `get()` + `_reset()` pair if it holds state (makes it unit-testable).
- **Public API** → `lua/pi/init.lua`, following the `local session = require("pi.sessions.manager").get(); if session then ... end` pattern with a nil guard.
- **Chat wiring (keymaps, send hook)** → `lua/pi/ui/chat/init.lua`: keymaps in `Chat:_set_keymaps()` (use `pbuf`/`hbuf` locals); "on submit" logic in `Chat:_send_message()` (the single funnel for `submit` + `submit_follow_up`).
- **History rendering** → `lua/pi/ui/chat/history.lua`; tool-specific rendering → `lua/pi/ui/chat/tools.lua`.
- **Highlight group** → `lua/pi/ui/highlights.lua` (derive from base groups with `default = true`).
- **README** → document the knob/keymap/API in the same change.
- **Tests** → unit spec in `tests/<name>_spec.lua`; e2e script per `references/testing.md`.

## Gotchas — quick reference (full 现象/根因/修法 in `references/gotchas.md`)

These are real bugs found while building features here; each cost time because it is invisible at a lower layer. Read the detail file before relying on a one-liner.

| # | Symptom | Fix in one line |
| --- | --- | --- |
| G1 | Buffer edit inside an `<expr>` mapping is silently dropped | defer the edit with `vim.schedule` |
| G2 | `<expr>` fallback inserts garbage like `<80>ku` | return the **literal** `"<Up>"`/`"<Down>"` angle-bracket string, never `vim.keycode`/`nvim_replace_termcodes` |
| G3 | History recall works once then can't walk further | `TextChangedI` is *deferred*; don't guard programmatic edits with a boolean flag — compare buffer text to the last applied text |
| G4 | Headless e2e: your `TextChanged` save hook never fires | headless `-l` does not fire `TextChanged` for programmatic edits; expose the save as a callable method and call it directly in the test |
| G5 | Headless e2e: an `<Up>` expr key "does nothing" | insert mode doesn't persist across `feedkeys`/`wait`; feed `"i<Up>"` in one call, or bind the key in `{ "i", "n" }` |
| G6 | "I can't verify the markdown looks right" | headless cannot see pixels; use a GUI screenshot (maim) — that is the only proof |
| G7 | Builtin code-block chrome looks redundant / breaks tool output | the history window is intentionally `conceallevel=0`; real chrome needs conceal, which conflicts — use the opt-in `render-markdown` engine instead |
| G8 | render-markdown "doesn't attach" in a spike | its auto-attach lives in `plugin/render-markdown.lua` (`manager.init()`); lazy runs it, a runtime `rtp:prepend` does not |
| G9 | render-markdown renders nothing on injected text headless | its render is async treesitter; force `require("render-markdown").render({ buf = buf })` in tests; interactively its own hooks handle it |
| G10 | markview ignores the history buffer | history is `buftype=nofile` and markview defaults `ignore_buftypes={"nofile"}`; prefer render-markdown (nofile works out of the box) |
| G11 | Programmatic focus of the history window bounces to the prompt | side layout's `WinEnter` auto-redirects when entering history from a non-prompt window; enter from the prompt, or expect the redirect |
| G12 | A leader/normal key "types a comma" into the prompt | the prompt auto-enters insert mode; send `Esc` first (real users and xdotool alike) |
| G13 | First keypress only loads the plugin, toggle seems dead | lazy loads on first use; `wait_for` the buffer, or call `pi.show()` over RPC to isolate |
| G14 | A plenary spec silently never runs and `make test` exits 1 | `before_each`/`after_each` must be **inside** a `describe`; at top level they no-op and fail the run |
| G15 | `make test` runs the wrong nvim / errors weirdly | don't name a Makefile var `NVIM` (nvim injects `$NVIM`); use `NVIM_BIN` |
| G16 | Your cleanup `pkill`/`pgrep` kills its own shell | a feature string inside an inline `bash -c` self-matches `pgrep -f`; put cleanup in a **script file** (clean cmdline) |
| G17 | Test run corrupts the user's prompt history / draft | redirect `prompt.history.path` and `Draft._set_path` to `/tmp`; move the user's draft aside and restore it |
| G18 | You almost delete a real session file | a stubbed send writes no transcript; a `grep` hit for your test text is usually inside an assistant quote — never delete sessions by grep |
| G19 | New config option "does nothing" | you edited only 1 of the 3 config spots (annotation / `pi.Options` / `defaults`) |
| G20 | `get()` returns stale config | read `require("pi.config").options` at call time, never cache at module load |

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

## Cross-references

- `references/architecture.md` — module map, the hard design constraints (modifiable toggle, `conceallevel=0`, WinEnter redirect, auto-insert, session-per-tab, extmark capture/restore), and the rationale behind each "standard place" above.
- `references/testing.md` — each test layer in depth: what to assert, the exact pitfalls, and how the templates avoid them; the isolation recipe; how to read a GUI screenshot as proof.
- `references/gotchas.md` — the full 现象 / 根因 / 修法 for G1–G20, with the minimal reproductions where one exists.
- Repo `AGENTS.md` — architecture charter, style, type-annotation and scheduling conventions (authoritative for *style*; this skill is authoritative for *testing*).
