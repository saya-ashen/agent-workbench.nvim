```text
            ████████████████████████    █████
              ██                ██          ██
              ██                ██       ████
              ██                ██      ██
              ██                ██      █████
              ██                ██
              p i ²    ·    p i 2 . n v i m
```

# pi2.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-green.svg?logo=neovim)](https://neovim.io)
[![pi](https://img.shields.io/badge/pi-0.65.2%2B-blue.svg)](https://pi.dev)

Use the [pi coding agent](https://pi.dev) without leaving Neovim — **π²**, a heavily extended fork of [`alex35mil/pi.nvim`](https://github.com/alex35mil/pi.nvim).

`pi2.nvim` runs `pi --mode rpc` in the background and gives you an in-editor workflow for project-aware prompts, reviewed edits, session resume, and extension prompts — plus a growing set of features that live here rather than upstream (see [Differences from upstream](#differences-from-upstream)).

> [!NOTE]
> The project is named **pi2.nvim** (π²), but the Lua namespace, commands, and filetypes are unchanged for compatibility: you still `require("pi")`, use the `:Pi*` commands, and the buffers keep the `pi-chat-*` filetypes. Only the project / repository name differs.

## Features

https://github.com/user-attachments/assets/55080963-3066-44c2-9017-a81828033ef7

<p align="center">
    <sub> Workflow demo </sub>
</p>

![pi2.nvim demo](assets/demo.gif)

<p align="center">
    <sub> pi2.nvim in action — agent reads, edits, and verifies a file with live streaming and <code>:PiTree</code> session navigation </sub>
</p>

<details>
<summary>Chat with an agent in a side panel or a floating window</summary>

https://github.com/user-attachments/assets/2ab6ea5c-7c52-4977-8a12-b5dee55affaa
</details>

<details>
<summary>Point an agent at the exact code with @-mentions</summary>

https://github.com/user-attachments/assets/c94b0099-f2d3-403a-962b-69bc23b78fb1
</details>

<details>
<summary>Run skills and commands</summary>

https://github.com/user-attachments/assets/eec9d926-724c-426d-a6ac-03c8a11530dc
</details>

<details>
<summary>Review agent-proposed edits in a two-way diff before they are applied, and tweak the proposed result if needed</summary>

https://github.com/user-attachments/assets/c20dfa72-79e4-4160-b7f0-6817b0793fda
</details>

<details>
<summary>Be notified when an agent needs your attention without interrupting your flow</summary>

https://github.com/user-attachments/assets/7b83bff0-b747-4232-9921-10a0955d58f7
</details>

<details>
<summary>Scroll chat history without leaving the prompt</summary>

https://github.com/user-attachments/assets/5f1b22a2-c682-4be1-8713-4155eca54437
</details>

<details>
<summary>See tool activity, diffs, and agent status inline, with collapsible tool blocks</summary>

https://github.com/user-attachments/assets/6df13dd4-2c1e-41c1-8be0-9ac71432e31d
</details>

<details>
<summary>Switch to zen mode for composing larger prompts comfortably</summary>

https://github.com/user-attachments/assets/b1074303-1f16-40d8-8413-55a7cb88a687
</details>

<details>
<summary>Queue follow-up instructions while the agent is still working</summary>

https://github.com/user-attachments/assets/c4a7b6e6-cf13-454e-b073-f3205ac3eda6
</details>

<details>
<summary>Switch models and thinking levels mid-session</summary>

https://github.com/user-attachments/assets/c8535554-ea69-4ea9-8098-6b63185bd410
</details>

<details>
<summary>Continue or resume past sessions for the current working directory</summary>

https://github.com/user-attachments/assets/d2d595db-e11d-40b7-87b0-5124867e160e
</details>

<details>
<summary>Keep separate conversations per tab</summary>

https://github.com/user-attachments/assets/4d087f23-c459-496d-92b9-7540be7340ce
</details>

<details>
<summary>Attach screenshots and other images from disk, clipboard, or drag-and-drop</summary>

https://github.com/user-attachments/assets/f210246a-2427-4fdb-b679-eeb6ceae4538
</details>

## Requirements

- Neovim 0.10+
- `pi` in `$PATH`
- [`MeanderingProgrammer/render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim) for the default chat-history renderer (`render.engine = "render-markdown"`)

Optional but useful:

- `nvim-treesitter` markdown parser for nicer chat history highlighting
- [`HakonHarnes/img-clip.nvim`](https://github.com/HakonHarnes/img-clip.nvim) for `:PiPasteImage`
- `blink.cmp` if you want popup completion in the π prompt buffer

Run `:checkhealth pi` to verify.

## Installation

### Installing with an agent

The easiest way to install `pi2.nvim` is to hand the job to an AI coding agent (pi, Claude Code, Cursor, …). Point your agent at the instructions below — they tell it how to detect your setup, what to add, and how to verify the result.

> **For the agent:** install the `pi2.nvim` Neovim plugin for the user by following these steps.
>
> 1. **Detect the plugin manager.** Read the user's Neovim config (usually `init.lua` under `stdpath("config")`, e.g. `~/.config/nvim/init.lua`) and find which plugin manager is in use — `lazy.nvim`, the built-in `vim.pack` (Neovim 0.11+), `packer.nvim`, etc. Follow that manager's spec conventions; if you can't tell which one is used, ask the user.
> 2. **Add the plugin and its dependency.** Add `zgs225/pi2.nvim` together with `MeanderingProgrammer/render-markdown.nvim`, which the default history renderer (`render.engine = "render-markdown"`) requires. Optionally add `HakonHarnes/img-clip.nvim` (needed only for `:PiPasteImage` clipboard-image paste). Use the specs under [Installing manually](#installing-manually) as a reference for the two most common managers.
> 3. **Recommended setup.** Ensure `require("pi").setup()` runs after the plugin loads. The defaults are a good first install — do not add options the user hasn't asked for. See [Configuration](#configuration) for the full option list, and [Keymaps](doc/keymaps.md) for a recommended mapping set; if the user already has `<Leader>` conventions, adapt to them rather than introducing new ones.
> 4. **Verify with the healthcheck.** After installing, run `:checkhealth pi` and confirm it reports OK: the `pi` executable is in `$PATH`, the pi backend version is compatible, Neovim is 0.10+, and the default renderer's dependencies resolve. Fix anything it flags — e.g. install `pi`, or set `cli = { bin = "/absolute/path/to/pi" }` if it isn't on `$PATH`.

### Installing manually

#### vim.pack

```lua
vim.pack.add({
    "https://github.com/zgs225/pi2.nvim",
    -- Default chat-history renderer (render.engine = "render-markdown"):
    "https://github.com/MeanderingProgrammer/render-markdown.nvim",
})

-- if you're fine with defaults:
require("pi").setup()

-- or, if you want to customize:
require("pi").setup({
    models = { ... },
    layout = { ... },
})
```

#### lazy.nvim

```lua
{
    "zgs225/pi2.nvim",

    -- render-markdown.nvim powers the default chat-history renderer
    -- (render.engine = "render-markdown"); img-clip.nvim is optional and
    -- required only for `:PiPasteImage` (clipboard image paste).
    dependencies = {
        "MeanderingProgrammer/render-markdown.nvim",
        "HakonHarnes/img-clip.nvim",
    },

    -- if you're fine with defaults:
    config = true,

    -- or, if you want to customize:
    opts = {
        models = { ... },
        layout = { ... },
        sessions_list = { ... },
    },
}
```

## Quick start

1. Open a project in Neovim.
2. Run `:Pi`.
3. Type a prompt and press `<CR>`.
4. Mention files with `@path/to/file` or `@path/to/file#L12-20`.
5. Use `:PiContinue` or `:PiResume` to revisit earlier sessions for the current working directory.

## Configuration

All options are optional — the defaults are a good first install. The full annotated reference lives in [doc/configuration.md](doc/configuration.md); these are the knobs people reach for most:

```lua
require("pi").setup({
    -- Curate the models you cycle through (:PiCycleModel / :PiSelectModel).
    models = {
        { match = "opus", latest = true },
        { match = "sonnet", latest = true },
    },

    -- Chat placement: "side" (default) or "float", left/right/bottom, sizing.
    layout = {
        default = "side",
        side = { position = "right", width = 80 },
    },

    -- Where search results land (:cnext / :cprev); see doc/usage.md#quickfix.
    quickfix = { grep = true, find = false },

    -- Everything else (statusline, diff keys, prompt behavior, zen, …):
    -- see doc/configuration.md
})
```

> [!IMPORTANT]
> `pi2.nvim` runs pi in RPC mode and does not implement the TUI's interactive project-trust prompt. Project-local pi files (settings, extensions, skills) are not loaded unless you opt in — see [Project trust](doc/configuration.md#project-trust).

## Keymaps

`pi2.nvim` ships a deliberately small default keymap set (submission, abort, history recall, `<Tab>` block toggles, `gf` file jumps, diff-review keys) and leaves the rest to you. See [doc/keymaps.md](doc/keymaps.md) for the key-spec format, the stable `pi-chat-*` filetypes, and a complete example setup you can adapt.

## Commands

| Command | Description |
| --- | --- |
| `:Pi [layout=side\|float]` | Open or toggle the chat in the current tab |
| `:PiContinue [layout=side\|float]` | Continue the most recent session for the current working directory |
| `:PiResume [layout=side\|float]` | Pick and resume a past session for the current working directory |
| `:PiToggleChat` | Toggle chat visibility |
| `:PiToggleLayout` | Switch between side and float layout |
| `:PiAbort` | Abort the current agent operation |
| `:PiAbortBash` | Abort the running direct bash (`!`) command |
| `:PiStop` | Stop the RPC process and close the chat |
| `:PiAttention` | Open the next queued attention request |
| `:PiNewSession` | Start a new conversation in the current tab/session |
| `:PiTree` | Navigate the session tree: jump back to any past conversation point |
| `:PiSessions` | Toggle the live sessions overview (all active sessions: name + busy/idle/attention) |
| `:PiToggleStartupDetails` | Toggle the startup block between compact and expanded |
| `:PiToggleThinking` | Show or hide thinking blocks |
| `:PiCycleThinking` | Cycle to the next thinking level |
| `:PiSelectThinking` | Pick a thinking level |
| `:PiCycleModel` | Cycle the current model |
| `:PiSelectModel` | Pick from configured models, or all models if none are configured |
| `:PiSelectModelAll` | Pick from all available models |
| `:PiSendMention` | Mention the current file; in visual mode or with a range, mention the selection lines |
| `:PiAttachImage {path}` | Attach an image file to the prompt |
| `:PiPasteImage` | Attach an image from the clipboard |
| `:PiCompact [instructions]` | Ask π to compact the current conversation context |
| `:PiSessionName [name]` | Set or show the session display name |
| `:PiToggleDebug` | Toggle RPC debug logging |

Every command also has a Lua API counterpart — see [doc/api.md](doc/api.md).

## Documentation

Detailed guides live in [`doc/`](doc/):

| Doc | What's inside |
| --- | --- |
| [doc/usage.md](doc/usage.md) | Chat & layouts, prompt (submit/queue/abort), direct bash mode (`!`), prompt history & drafts, `@mentions`, slash commands, completion, attachments, zen mode, statusline, navigation, quickfix, tool blocks, models, thinking, markdown rendering, buffer reload, startup block |
| [doc/sessions.md](doc/sessions.md) | One session per tab, storage & cwd scoping, continue/resume, session tree (`:PiTree`), sessions overview (`:PiSessions`), compaction |
| [doc/diff-review.md](doc/diff-review.md) | Two-way diff review of agent edits, review notes, permission-extension protocol reference |
| [doc/attention.md](doc/attention.md) | Attention queue, dialogs, notifications, queue inspection API |
| [doc/extensions.md](doc/extensions.md) | Extension UI routing, startup announcements, `on_widget` custom blocks, adapting non-upstream RPC backends |
| [doc/configuration.md](doc/configuration.md) | Full annotated defaults + project trust |
| [doc/keymaps.md](doc/keymaps.md) | Key specs, stable filetypes, example setup |
| [doc/api.md](doc/api.md) | Lua API reference |
| [doc/highlight-groups.md](doc/highlight-groups.md) | All `Pi*` highlight groups |
| [doc/troubleshooting.md](doc/troubleshooting.md) | `:checkhealth pi`, RPC debug logging, process lifecycle, triage checklist |

## Origin

`pi2.nvim` is a fork of [`alex35mil/pi.nvim`](https://github.com/alex35mil/pi.nvim), the original Neovim frontend for the [pi coding agent](https://pi.dev). All credit for the foundation — the RPC bridge, the chat layout, diff review, sessions, and extension handling — goes to the upstream project.

This fork began as local experiments and grew into a substantially different feature set (listed below). Rather than keep that work on a long-lived fork, it now lives in its own repository so it can evolve and release independently, while still tracking upstream where it makes sense and crediting it as the origin.

## Differences from upstream

Everything below is present in `pi2.nvim` and **not** in upstream `alex35mil/pi.nvim` (which is currently frozen at the fork point). Each entry links to its full documentation.

**Prompt & input**

- [Dynamic `@mention` providers](doc/usage.md#dynamic-mentions) — `@git-diff`, `@git-log`, `@lsp-errors`, `@quickfix` (plus custom `mention_providers`) attach live state to your message at send time.
- [Direct bash mode (`!`)](doc/usage.md#direct-bash-mode-) — run shell commands straight from the prompt, output streams into the chat and joins the next prompt's context.
- [Readline-style prompt history](doc/usage.md#prompt-history) — `<C-p>` / `<C-n>` recall, persisted to disk.
- [Unsent-draft persistence](doc/usage.md#draft-persistence) — the prompt text survives restarts.
- [Clipboard image paste](doc/usage.md#attachments) — pasting into the prompt while the clipboard holds an image attaches it; the rest of the editor's paste is untouched.
- [Image compression for attachments](doc/usage.md#image-compression) — downscale/re-encode before sending (sips / magick / ffmpeg).

**Agent control**

- [Double-`<Esc>` abort](doc/usage.md#aborting-with-double-esc) — a second `<Esc>` within a timeout aborts the running turn, with a persistent statusline hint.

**UI & rendering**

- [Redesigned tool & thinking blocks](doc/usage.md#tool-blocks) — fold indicators + indentation, silent success, animated spinners, single-line thinking headers with rolling preview.
- [Status line in the prompt](doc/usage.md#statusline) — busy spinner with elapsed time, context/cost/token usage, queue count, and abort hints pinned to the prompt window.
- [`render-markdown.nvim` engine](doc/usage.md#markdown-rendering) — the default renderer, with a builtin treesitter fallback.

**Navigation & layout**

- [Open file under cursor (`gf`)](doc/usage.md#open-file-under-cursor) — resolves bare paths, `@mention#L<line>`, and `path:line` from history lines.
- [Search results in the quickfix list](doc/usage.md#quickfix) — `grep`/`find` results loaded for `:cnext` / `:cprev`.
- [Left side panel](doc/usage.md#chat--layouts) — `layout.side.position` accepts `"left"`.

**Sessions & editor integration**

- [Sessions overview (`:PiSessions`)](doc/sessions.md#sessions-overview-pisessions) — a live, shared dashboard of every active session with animated status dots.
- [Session tree navigation (`:PiTree`)](doc/sessions.md#session-tree-navigation-pitree) — jump back to any past conversation point, optionally summarizing the abandoned branch.
- [Per-tab model pinning](doc/usage.md#per-tab-model-pinning) — model switches in one tab don't leak into other tabs' new sessions.
- [Auto-reload of open buffers](doc/usage.md#buffer-reload) — files modified by the agent reload in place; unsaved buffers are never touched.

**Robustness fixes**

- Thinking blocks render after inline tools (correct turn order); CJK / UTF-8 thinking-preview truncation no longer corrupts text; tool-block collapse/expand no longer corrupts the footer extmark; nerd-font icon codepoints corrected.
- The streaming thinking header no longer flickers (the rolling preview is drawn as end-of-line virtual text instead of `inline`).
- The busy spinner and abort hints live in the prompt statusline at a fixed position that never scrolls away.

**Developer infrastructure**

- A hermetic plenary test suite (`make test`) plus a headless boot check (`make smoke`), and an agent "develop" skill documenting the test stack and Neovim-Lua gotchas.

## License

[MIT](LICENSE)
