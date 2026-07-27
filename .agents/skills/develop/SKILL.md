---
name: develop
description: Use when developing, testing, debugging, or adding/changing features in this pi.nvim plugin. Covers the full feature lifecycle (issue → branch → implement → test → review → merge → close), the three-layer test stack, Neovim-Lua gotchas, and the standard places a change lands. Read this before touching lua/pi/** or tests/**.
---

# Developing & testing pi.nvim

Operational playbook for taking a feature from idea to merged code. `AGENTS.md` is the architecture charter; this skill is authoritative for **workflow and testing**.

## Feature lifecycle

```mermaid
flowchart TD
    A["💡 Feature idea"] --> B["Gitea issue\nlabels: rpc|original · priority:* · review:pending"]
    B --> C{"Maintainer triage"}
    C -- wontfix --> D["review:wontfix · close"]
    C -- approve --> E["review:approved"]
    E --> F["git checkout -b feat/<name>"]
    F --> G["Implement\n(config → module → wiring → tests → README → CHANGELOG)"]
    G --> H{"make test\nmake smoke"}
    H -- fail --> G
    H -- green --> I["git commit · push feat/<name>"]
    I --> J["Implementation comment on issue\nlabel: pr:awaiting-review"]
    J --> K{"Human code review"}
    K -- changes requested --> L["pr:changes-requested"] --> G
    K -- approved --> M["pr:approved"]
    M --> N["merge --no-ff → push main\ndelete feat branch"]
    N --> O["Close issue"]
```

### Phase rules

| Phase | Key rules |
|-------|-----------|
| Issue | Body is the spec — never overwrite it. Implementation notes go in **comments**. Labels: type (`rpc`/`original`), priority, review gate. |
| Branch | `feat/<short-kebab-name>`. Baseline `make test && make smoke` green before starting. |
| Implement | Follow the **standard places** checklist below. Config knobs touch **three** spots in `config.lua` (G19). |
| Test | Cheapest layer that can observe the behavior. State what was verified and what was not. |
| PR | Push branch → implementation comment → `pr:awaiting-review`. |
| Review | `pr:changes-requested` → fix → re-push → back to `pr:awaiting-review`. `pr:approved` → merge. |
| Merge | `git merge --no-ff`, push main, delete remote+local branch, close issue. |

Gitea API: `https://git.yuez.me/api/v1/repos/yuez/pi.nvim`, auth via `GITEA_TOKEN` (chezmoi-encrypted in `~/.zshrc.local`).

## Verification layers

| Layer | Command | Sees | Cannot see |
|-------|---------|------|------------|
| Unit (plenary) | `make test` | pure-Lua logic, config resolution | buffers, windows, keys, rendering |
| Headless e2e | `make smoke` / `nvim --headless -l script.lua` | plugin load, RPC, buffer/extmark wiring | visual rendering, real key events |
| GUI automation | `scripts/gui_launch.sh` + `gui_harness.sh` | real keybindings, insert mode, **pixels** | — (top layer, slow) |

Details, pitfalls, isolation recipe, and script usage: `references/testing.md`.

## Standard places a new feature lands

- **Config knob** → `lua/pi/config.lua` — three spots: `---@class` annotation, `pi.Options` field, `defaults` table (G19).
- **Pure logic** → `lua/pi/<name>.lua`, one table returned, `_` prefix for private, `_reset()` for testability.
- **Public API** → `lua/pi/init.lua`, nil-guard on `Sessions.get()`.
- **Chat wiring** → `lua/pi/ui/chat/init.lua`: keymaps in `_set_keymaps()`, submit logic in `_send_message()`.
- **History rendering** → `lua/pi/ui/chat/history.lua`; tool renderers → `lua/pi/ui/chat/tools.lua`.
- **Highlight group** → `lua/pi/ui/highlights.lua` (`default = true`).
- **README + CHANGELOG** → in the same commit for user-facing changes.
- **Tests** → `tests/<name>_spec.lua`; e2e per `references/testing.md`.

## Gotchas

One-line quick reference below; full 现象/根因/修法 in `references/gotchas.md`.

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

## Cross-references

- `references/architecture.md` — module map, hard design constraints, rationale for standard places.
- `references/testing.md` — layer details, pitfalls, isolation recipe, verification discipline, script usage.
- `references/gotchas.md` — full 现象/根因/修法 for G1–G21 with minimal reproductions.
- `AGENTS.md` — architecture charter, style, type-annotation conventions.
- `.agents/skills/commit/SKILL.md` — Conventional Commit format, CHANGELOG rules, breaking-change policy.
