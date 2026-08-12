# Health & debugging

When something misbehaves — the agent doesn't respond, a tool doesn't render correctly, an extension event doesn't arrive — pi2.nvim gives you a few places to look.

## `:checkhealth pi`

The health check verifies:

- **Neovim version** — 0.10 or newer.
- **The `pi` executable** (from `cli.bin`, defaults to `"pi"`) exists and is in `$PATH`, and its version against the plugin's tracked range:
  - minimum supported: `0.65.2`
  - last validated: `0.79.3`
  - older versions are a hard error; newer versions are reported as unvalidated (warning), not hard-failed.
- **Treesitter parsers** — `markdown` and `markdown_inline` (info-only; chat highlighting is limited without them).
- **Optional plugins** — `img-clip.nvim` (clipboard image paste), `render-markdown.nvim` (warned when it's the configured engine but missing), `blink.cmp` (info-only).
- **The bundled tree extension** — `extensions/tree.ts` exists when `tree.enabled` is on (`:PiTree` depends on it).
- **Image compression tools** — when `prompt.image_compress` is enabled, at least one of `sips` / `magick` / `ffmpeg` is found (warns if you pinned a specific `tool` that's missing).

Run it any time you suspect something is off with the install:

```vim
:checkhealth pi
```

If the executable isn't found, either install pi or set `cli = { bin = "/absolute/path/to/pi" }` in `setup()`.

## RPC debug logging

pi2.nvim communicates with the backend over a JSONL RPC protocol on the pi process's stdin/stdout. When that conversation goes wrong, the best diagnostic is a transcript of the protocol traffic.

There are two ways to enable it:

- **Statically**, from the start of every session: `debug = true` in `setup()`.
- **At runtime**, toggled on/off without restarting anything: `:PiToggleDebug` / `pi.toggle_debug()`. This override is in-memory only and lasts for the current Neovim session; restart clears it back to whatever `setup()` said.

Logs are written to:

```
<stdpath("log")>/pi/<cwd-slug>/rpc.log
```

where `<cwd-slug>` is the current working directory with `/` replaced by `--`. On a typical Linux setup that's something like `~/.local/state/nvim/log/pi/home--you--Dev--myproject/rpc.log`. The log is **reset** every time debug is enabled, so each session starts with a clean transcript.

The log contains every RPC command pi2.nvim sends and every event it receives, including any unhandled event types (useful when the pi protocol evolves and pi2.nvim hasn't caught up yet). Tailing the file in another terminal while reproducing the bug is usually the fastest way to pinpoint where things diverge:

```sh
tail -f ~/.local/state/nvim/log/pi/*/rpc.log
```

When filing an issue, attaching the relevant section of `rpc.log` is by far the most useful thing you can include.

## Process lifecycle

Each π session owns an underlying `pi --mode rpc` subprocess and a listed History buffer. Lifecycle:

- **Spawned** when `:Pi`, `:PiNewSession`, `:PiContinue`, or `:PiResume` creates a session buffer. No background daemon runs before first session.
- **Alive** while History buffer exists. Hiding chat, switching buffers, or closing a tab does **not** stop process.
- **Torn down** by `:bdelete` / `:bwipeout` on History buffer, or by `VimLeavePre` for all sessions.
- **Stopped explicitly** via `:PiStop` / `pi.stop()` — kills current session RPC and deletes its History buffer.
- **Aborted** via `:PiAbort` / `pi.abort()` — cancels whatever the agent is currently doing mid-turn but keeps the session and process alive, so you can immediately send a new prompt. Different from `:PiStop`: abort stops the _agent_, stop kills the _process_.

## What to check when something's wrong

A rough triage checklist for common symptoms:

| Symptom | First thing to check |
| --- | --- |
| `:Pi` does nothing / reports no executable | `:checkhealth pi` — is `bin` resolvable? |
| Chat opens but never gets a response | Enable debug logging and watch `rpc.log` — are commands going out? Are events coming back? |
| Diff review doesn't open on edit/write | Is a permission extension loaded? See [Diff review](diff-review.md). |
| Extension UI request ignored | Check the extension's `widgetKey` / method — is it something pi2.nvim knows how to route? See [Extensions](extensions.md). |
| Slash command not highlighted | The command cache may not be populated yet (fetched on first chat open, refreshed every 30 seconds). |
| Session doesn't continue with `:PiContinue` | Are you in the same cwd as when the session was started? Sessions are cwd-scoped — see [Sessions](sessions.md). |
| Statusline component shows stale data | The statusline is pushed from RPC events; if they stopped flowing, `rpc.log` will show the gap. |
| Unhandled event warning | pi2.nvim doesn't yet know about a new event type the backend is sending. Please [open an issue](https://github.com/zgs225/pi2.nvim/issues) with the event name and a snippet of `rpc.log`. |
| `:PiTree` shows "Failed to decode RPC message: Found too many nested data structures" | The `get_tree` response for a very long session (roughly 500+ messages) is deeper than Neovim's built-in JSON decoder allows. See [Deep RPC payloads](#deep-rpc-payloads) below. |

## Deep RPC payloads

Neovim's `vim.json` (the bundled lua-cjson library) hard-caps JSON nesting at 1000 levels, which cannot be raised at runtime. The pi backend nests the session tree one level **per message**, so `get_tree` responses for long sessions — and with it `:PiTree` — used to fail with `Failed to decode RPC message: Found too many nested data structures (1001) at character N`, and the tree picker never opened.

Since 2026-08-11 pi2.nvim ships its own depth-tolerant JSON decoder (`pi.json`) as a fallback: incoming RPC lines that cjson refuses are re-decoded with it, so `:PiTree` works for sessions up to roughly 4000 messages (the fallback's defensive depth cap). Only when both decoders fail does the warning still appear — normally a sign of a genuinely malformed line; enable [RPC debug logging](#rpc-debug-logging) and check `rpc.log` in that case.
