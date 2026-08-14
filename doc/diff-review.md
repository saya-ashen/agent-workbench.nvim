# Diff review

When an `edit` or `write` tool is about to run, pi2.nvim can intercept it and open a two-way diff in a new tab so you can inspect, tweak, and accept or reject the change _before_ it lands on disk. This is the main review surface for agent-driven refactoring.

Once the diff is open:

- **Left pane** — the current file content, opened read-only.
- **Right pane** — the content the agent is proposing. You can modify the _right_ pane before accepting — anything you change there becomes the new content and pi2.nvim will write your edited version instead of the agent's original proposal.
- **Accept** with `<Leader>da` (default) — or just `:w` the right pane. If disk write or close fails, review stays open and no acceptance response is sent.
- **Reject** with `<Leader>dr`.
- **Add/edit a review note** on the current line with `<Leader>dn`, or select multiple lines with `V` first to attach one note to the selected range. In the note dialog, `<CR>` submits and `<S-CR>` inserts a newline. Notes are review metadata: they show below the last target line as wrapped virtual text with a vertical border, plus a configurable sign/icon on the first line. Range notes use small dots on following lines. Multiple note blocks ending on the same line are separated by a horizontal separator. They are not inserted into the file. Set `diff.icons.note = false` to omit gutter signs. Submitting an empty note deletes it.
- **Delete a review note** on the current line with `<Leader>dx`. If multiple notes cover the cursor line, choose one from a picker.
- **List review notes** with `<Leader>dN`; selecting an entry jumps to the first noted line.
- **Expand / shrink** the surrounding diff context with `<Leader>de` / `<Leader>ds`. The initial context comes from `diff.context.base` (or `'diffopt'` when unset), and the step size from `diff.context.step`.

All keys are configurable under `diff.keys` using the [Key specs](keymaps.md#key-specs) format, so you can bind multiple keys, pin modes, or replace them entirely. By default, the proposed-pane winbar shows `?=keymaps`; pressing `?` opens an informational dialog listing the configured diff review keymaps. Set `diff.keymap_hints = "winbar"` to show full inline winbar hints, or `false` to hide hints and bind no help key. `true` aliases the default dialog mode. If `?` conflicts with a diff action key, the action key wins and the help binding/hint is omitted.

Markdown diffs enable wrapping and linebreak in the review panes for readability. Other filetypes keep your global `wrap` and `linebreak` defaults.

## Session diff review (`:PiDiff`)

Where the two-way review above intercepts a single edit _before_ it lands, `:PiDiff` reviews everything the session already changed, after the fact. It opens the combined `git diff` of every file the current session's `edit`/`write` tools touched (`session.changed_files`) in **one review panel**: a single floating window whose border and background frame two side-by-side areas — the file list on the left, the selected file's diff on the right.

- **File list** (left, `pi-diff-review` filetype) — one row per changed file with an `A`/`M`/`D` status letter (added / modified / deleted) in the diff semantic colors. Moving the cursor shows that file's diff on the right; `<CR>`/`o` jumps to its first changed line. **`<C-f>` / `<C-b>`** page the diff, **`<C-d>` / `<C-u>`** scroll it by half a page, all without leaving the list.
- **Diff area** (right) — the selected file's unified diff, rendered with the `diff` filetype for native syntax highlighting, with a `── path ──` header. `<CR>`/`o` on a hunk line jumps to that exact line (line numbers are tracked per hunk, so added and context lines land precisely; removed lines jump to the deletion point; deleted files have no target); `q` closes. Click or `<C-w>w` to move focus into the diff area, where any native scrolling (`j`/`k`, `gg`/`G`, `z.`, …) works.

`q` anywhere in the panel closes the whole review; closing any of its windows closes the rest. Re-running `:PiDiff` refreshes (it always re-reads `git diff`).

Files the agent created render as full-file additions (git's `--no-index` mode). Files outside the current git repository are skipped and counted in the list hint line. Hunk context follows `'diffopt'` (`context:`), matching the two-way review.

`diff_review` config sizes the panel:

```lua
-- setup()
diff_review = {
    width = 0.8, -- panel width: fraction (<1) of editor width, or columns (>=1)
    height = 0.8, -- panel height: fraction (<1) of editor height, or lines (>=1)
    border = "rounded",
    list = {
        position = "left", -- file list inside the panel: "left" | "right"
        width = 30, -- file list width in columns
    },
},
```

Unlike the pre-execution review, `:PiDiff` needs no permission extension: it only reads `git diff` output and never writes to disk.

## You need a permission extension

Here's the part to understand before the rest of this section makes sense: **pi itself has no built-in permission system**. The agent dispatches tools whenever it decides to, and by default nothing stands between it and your files. pi2.nvim's diff review _only_ triggers when an extension intercepts `edit`/`write` tool calls and routes them through a specially-formatted `ctx.ui.select` request.

In other words, **without a permission extension, there is no diff review**. The agent will apply edits directly, and you'll see them in the chat history as completed tool calls, not as reviewable diffs.

If you want a drop-in, fully-featured solution, use my reference implementation: [**alex35mil/agentic-af/extensions/permission**](https://github.com/alex35mil/agentic-af/tree/main/extensions/permission). It is very similar to Claude Code's allow / ask / deny model with glob rules, per-tool argument matching, skill-derived allowances, bash argument splitting and redirection safety, and an auto-accept toggle.

If you'd rather roll your own, or just want to understand the protocol, here's a minimal pi extension that intercepts `edit` and `write` tool calls, routes them through pi2.nvim's diff review UI, and handles all response variants.

<details>
<summary><strong>Minimal example</strong> — click to expand</summary>

```ts
/**
 * Minimal diff-review permission extension for pi + pi2.nvim.
 * Intercepts every `edit` and `write` tool call and routes it through
 * pi2.nvim's diff review UI via ctx.ui.select.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

// Track which tool calls the user approved so we can flip the
// blocked-isError flag back in a message_end handler.
const approvedToolCalls = new Set<string>()

type ReviewNote = {
    path: string
    side: "current" | "proposed"
    /** 1-indexed inclusive range. */
    lineStart: number
    lineEnd: number
    lines: string[]
    note: string
}

function formatNotes(notes?: ReviewNote[]) {
    if (!notes?.length) return ""
    return "\n\nReview notes:\n" + notes.map((n) => {
        const range = n.lineStart === n.lineEnd ? `${n.lineStart}` : `${n.lineStart}-${n.lineEnd}`
        return `- ${n.side}:${range} ${JSON.stringify(n.lines)}\n  ${n.note}`
    }).join("\n")
}

export default function (pi: ExtensionAPI) {
    pi.on("tool_call", async (event, ctx) => {
        if (event.toolName !== "edit" && event.toolName !== "write") {
            return undefined // other tools run without review
        }

        if (!ctx.hasUI) {
            return {
                block: true,
                reason: `[rejected] No UI available to review ${event.toolName}`,
            }
        }

        const path = (event.input as { path?: string }).path
        if (!path) return undefined

        // Build the payload pi2.nvim recognizes as a diff review request.
        const title = JSON.stringify({
            prompt: `${event.toolName}: ${path}`,
            toolName: event.toolName,
            toolInput: event.input,
        })
        const choice = await ctx.ui.select(title, ["Accept", "Reject"])

        // pi TUI path: plain "Accept" — let the tool run normally.
        if (choice === "Accept") {
            return undefined
        }

        // pi2.nvim path: structured JSON response.
        if (choice?.startsWith("{")) {
            const parsed = JSON.parse(choice)

            if (parsed.result === "Accepted") {
                // pi2.nvim already wrote the file — block the tool so
                // pi's dispatcher doesn't double-write.
                approvedToolCalls.add(event.toolCallId)
                return {
                    block: true,
                    reason: `[accepted] User approved the edit. Changes applied to ${path} as proposed.` + formatNotes(parsed.notes),
                }
            }

            if (parsed.result === "AcceptModified") {
                // pi2.nvim wrote a user-modified version of the file.
                approvedToolCalls.add(event.toolCallId)
                return {
                    block: true,
                    reason:
                        `[accepted] User approved with modifications. ${path} was updated with user's version, which differs from what you proposed.` +
                        formatNotes(parsed.notes) +
                        `\n\nCurrent content of ${path}:\n` +
                        "```\n" + parsed.content + "\n```",
                }
            }

            if (parsed.result === "Rejected") {
                // Rejected with review notes: keep the file unchanged, but let
                // the turn continue so the agent can address the feedback.
                return {
                    block: true,
                    reason: `[rejected] User rejected the edit to ${path}. File unchanged.` + formatNotes(parsed.notes),
                }
            }
        }

        // Rejected without review notes, cancelled, or unknown response: stop the turn.
        ctx.abort()
        return {
            block: true,
            reason: `[rejected] User rejected the edit to ${path}. File unchanged.`,
        }
    })

    // Blocked tool results come back as isError=true. Flip that back
    // for approved calls so the agent doesn't treat accepted edits as
    // failures.
    pi.on("message_end", async (event) => {
        const msg = event.message as { role?: string; toolCallId?: string; isError?: boolean }
        if (msg.role !== "toolResult") return
        if (typeof msg.toolCallId !== "string") return
        if (approvedToolCalls.delete(msg.toolCallId)) {
            msg.isError = false
        }
    })
}
```

Drop that file into your pi extensions directory (usually `~/.pi/agent/extensions/<name>/index.ts`) and pi will load it on the next session. See the [pi extensions docs](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) for how extensions are discovered and registered.

</details>

## Protocol reference

pi2.nvim routes an extension `select` request to the diff review UI if and only if:

1. The request method is `select`, and
2. The `title` field is a JSON string that decodes to an object with `toolName === "edit"` or `"write"`.

Otherwise it's treated as a regular select picker.

**Request payload** (`JSON.stringify` this and pass it as the `title` argument to `ctx.ui.select`):

```json
{
  "prompt": "edit: /abs/path/to/file.ts",
  "toolName": "edit",
  "toolInput": {
    "path": "/abs/path/to/file.ts",
    "edits": [{ "oldText": "...", "newText": "..." }]
  }
}
```

For `write`, replace `edits` with `"content": "<full file text>"`.

**Response** (the value returned from `await ctx.ui.select(...)`):

| Value | Meaning | Extension should… |
| --- | --- | --- |
| `"Accept"` | Only returned by the pi TUI, not by pi2.nvim. | Return `undefined` and let the tool run normally. |
| `'{"result":"Accepted","notes":[...]}'` | User accepted. pi2.nvim already wrote the file. `notes` is omitted when empty. | Return `{ block: true, reason: "[accepted] ..." }` so pi doesn't double-write. Include notes in `reason` when present. |
| `'{"result":"AcceptModified","content":"...","notes":[...]}'` | User edited the proposal, then accepted. pi2.nvim already wrote the modified version. `notes` is omitted when empty. | Return `{ block: true, reason: "[accepted] ..." }`, ideally including the modified content so the agent sees the final state. Include notes when present. |
| `'{"result":"Rejected","notes":[...]}'` | User rejected with review notes. File unchanged. | Return `{ block: true, reason: "[rejected] ..." }` with the notes. Do **not** call `ctx.abort()` if you want the agent to continue and address the notes. |
| Anything else (`"Reject"`, `undefined`, cancellation) | User rejected without notes. | Return `{ block: true, reason: "[rejected] ..." }`; call `ctx.abort()` if rejection should stop the turn. |

Review notes are attached to the selected side and line range at review time. `lineStart`/`lineEnd` are 1-indexed inclusive; `lines` contains the text for that range.

```json
{
  "path": "/abs/path/to/file.ts",
  "side": "current",
  "lineStart": 42,
  "lineEnd": 44,
  "lines": [
    "const value = oldName()",
    "useValue(value)",
    "return value"
  ],
  "note": "Keep this name; it is part of the public API."
}
```

For `AcceptModified` specifically, it's important to surface the final content back to the agent — not just the fact that the edit was accepted. The proposal the agent made and the bytes that actually landed on disk are no longer the same, and if the agent assumes its proposal went through verbatim it will reason about a file state that doesn't exist. The reference extension uses a `reason` string along these lines:

> `[accepted] User approved with modifications. <path> was updated with user's version, which differs from what you proposed. Current content of <path>:`
> ` ```
`
> `<full modified content>
`
> ` ``` `

This gives the agent three things in one message: confirmation that the edit landed, an explicit note that the user changed it, and the new authoritative content so the next turn starts from the right file state.

The `[accepted]` and `[rejected]` prefixes in the `reason` string are parsed by pi2.nvim and used to pick the tool-call display status (completed vs rejected) in the chat history — see [Tool blocks → Status resolution](usage.md#status-resolution).

Because pi2.nvim writes the file _itself_ for `Accepted` and `AcceptModified`, the extension **must** return `{ block: true }` in those cases. If it doesn't, pi's tool dispatcher will run the original `edit`/`write` on top of pi2.nvim's version and you'll end up with a double-apply.

Blocked tool results come back to the agent with `isError: true`. For approved-but-blocked calls, flip that back in a `message_end` handler (as the minimal example does) so the LLM doesn't treat an accepted edit as a failure on the next turn.
