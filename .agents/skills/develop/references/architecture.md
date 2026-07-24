# Architecture — the developer's view

`AGENTS.md` has the full module tree and style rules; this file records the **design constraints that constrain where and how you can add things**, plus the rationale for the "standard places" checklist in `SKILL.md`. Re-read the actual file before editing — these notes explain *why*, not *what the code currently says*.

## The event pipeline (where your code runs)

```
pi --mode rpc  ──stdin/stdout JSON──▶  rpc.lua
   ──▶ sessions/manager.lua:handle_event()   (central dispatcher, per-tab session)
        ──▶ Chat (ui/chat/init.lua)          (orchestrates layout + prompt + history)
             ──▶ ChatHistory (ui/chat/history.lua)   (renders into the buffer)
             ──▶ Tools renderers (ui/chat/tools.lua) (per-tool on_start/on_end)
```

Every UI mutation that originates from an RPC callback **must** be on a `vim.schedule` (the callback is not on the main loop). The history buffer is the single source of visual truth; there is no separate view model.

## Hard design constraints (read before fighting them)

These are intentional and load-bearing. Most "this is harder than it should be" moments come from colliding with one of them.

- **History buffer is `modifiable=false`.** All writes go through `History:_with_modifiable(fn)` (toggle → run → restore). If you write to the history buffer directly you will error or leave it modifiable. Tool-block line insertion uses `History:_append_lines` / `History:_insert_lines`, which handle the toggle.
- **`conceallevel=0` on the history window (deliberate).** Tool output must show verbatim, so treesitter is not allowed to conceal anything there. Consequence: any "pretty" rendering that relies on concealing source markers (e.g. hiding the ` ```lang ` fence to draw a code-block box) **cannot** work in the builtin renderer without also mangling tool output. This is why rich code-block chrome is delivered by the opt-in `render-markdown` engine (`render.engine = "render-markdown"`), not bolted onto builtin. Don't add conceal-based chrome to builtin.
- **Extmarks carry the structure.** Tool borders, highlights, spinners, thinking anchors, and collapse ranges are all extmarks in namespace `pi-chat`. When you replace lines you must capture extmarks before and restore after (`capture_extmarks` / `restore_extmarks` in `history.lua`) or collapse/highlight state desyncs.
- **Tables and code fences are tracked by *parity*, not a parser.** The builtin renderer counts ` ``` ` lines and auto-closes an odd count, because an unclosed fence bleeds treesitter "code" styling into everything below. If you emit prose that contains fence-like lines (tool output does), preserve that parity logic.
- **Side layout auto-redirects focus to the prompt.** A `WinEnter` autocmd on the history buffer sends focus to the prompt when you enter history from a *non-prompt* window (so typing always lands in the prompt). Entering history *from the prompt* does not redirect. Implication: programmatic `nvim_set_current_win(history_win)` from an editor window triggers the redirect on the next tick; tests and "jump to file" flows must account for it (see G11).
- **The prompt auto-enters insert mode.** On focus it runs `startinsert`. So normal/leader mappings only fire after `Esc`. This is a user-facing fact *and* an automation fact (G12).
- **Session-per-tab.** `sessions[tab]` holds at most one `{ rpc, chat }`. `require("pi.sessions.manager").get()` returns the current tab's session (or nil). Public API in `init.lua` nil-guards on it. Cleanup on `TabClosed` / `VimLeavePre`. A new feature that needs "the chat" goes through `get().chat`, never a global.
- **Config is read live.** Always `require("pi.config").options` at call time. Caching a config value at module load (G20) yields stale values after `setup()`.
- **Lazy loading.** `pi` is loaded on first use (a keymap/command). In tests, `wait_for` the chat buffers rather than assuming `require("pi")` already ran; or force it with `pcall(require,"pi")` / `pi.show()`.

## Why each "standard place" is where it is

- **`config.lua` three spots** — the annotation drives LuaLS/user docs, `pi.Options` is the typed surface, `defaults` is the runtime fallback; `vim.tbl_deep_extend("force", defaults, opts)` means a key absent from `defaults` can't be overridden cleanly and won't show in the documented defaults block. Keep all three in sync (G19).
- **Pure module + `get()`/`_reset()`** — a process-wide singleton behind `get()` lets the wiring use one instance while `_reset()` plus a path override hook (`_set_path`) make the same module hermetically unit-testable and redirectable for isolation (G17). See `prompt_history.lua` and `draft.lua` for the pattern.
- **`_send_message()` is the submit funnel** — both `submit()` (steer-when-streaming) and `submit_follow_up()` route through it, and it holds the *raw* pre-expansion text. Anything that must happen "on send" (record history, clear draft) belongs here, once, not in each caller.
- **Keymaps in `_set_keymaps()`** — it is idempotent (`_keymaps_set` guard) and has `pbuf`/`hbuf` locals; binding elsewhere duplicates buffers lookups and risks double-binding on re-show. Buffer-local bindings here override globals, which matters for keys like `<Up>`/`<Down>`/`gf` that you intentionally repurpose.
- **Highlights in `highlights.lua`** — groups are derived from base groups (`Comment`/`Function`/`Title`/`DiagnosticError`/`WarningMsg`) with `default = true` and re-applied on `ColorScheme`/`VimEnter`, so themes can override and so a colorscheme change doesn't leave stale colors. Add new groups the same way; don't hard-code hex.

## Reference frontend

Per `AGENTS.md`, the pi TUI interactive mode is the reference for *behavior* (event flow, state, edge cases). Mirror its semantics, adapt to the buffer/extmark model. Don't invent divergent behavior for a feature the TUI already defines.
