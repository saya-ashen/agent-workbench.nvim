# Gitea via tea CLI

All Gitea interaction goes through `tea` (`/usr/bin/tea`, 0.15.1, installed via eos-bootstrap `pacman_packages`). **Never hand-roll curl against the API** — labels/state must be set through tea so commands stay reproducible.

## Login

Done once (token from chezmoi-encrypted `GITEA_TOKEN` in `~/.zshrc.local`):

```bash
tea login add --url https://git.yuez.me --token "$GITEA_TOKEN" --name yuez
tea whoami   # verify
```

`tea` stores config in `~/.config/tea/config.yml`. Outside a repo checkout, always pass `-r yuez/pi2.nvim`; inside the repo it is discovered from the git remote.

## Issue lifecycle cheat sheet

| Action | Command |
|--------|---------|
| Create | `tea issue create -r yuez/pi2.nvim -t "<title>" -d "$(cat body.md)" -L "rpc,priority:low,review:pending"` |
| List | `tea issue list -r yuez/pi2.nvim` |
| Show one | `tea issue show -r yuez/pi2.nvim <index>` |
| Comment (implementation notes) | `tea comments add -r yuez/pi2.nvim <index> "note"` |
| Add labels (triage → approved) | `tea issue edit -r yuez/pi2.nvim <index> -L "review:approved"` |
| Swap labels | `tea issue edit -r yuez/pi2.nvim <index> -L "pr:awaiting-review" --remove-labels "review:pending"` |
| Close | `tea issue close -r yuez/pi2.nvim <index>` |
| Reopen | `tea issue open -r yuez/pi2.nvim <index>` |

## Conventions

- Issue **body is the spec** — never overwrite it (`tea issue edit -d` only for typos). Implementation notes go in **comments** (`tea comments add`).
- Labels: type `rpc` / `original`, `priority:{high,medium,low}`, review gate `review:pending` → `review:approved` → `pr:awaiting-review` / `pr:changes-requested` / `pr:approved`.
- `-L` takes a comma-separated list; `--remove-labels` mirrors it. `--add-labels`/`--remove-labels` also exist for non-destructive updates.
- Multiline bodies: write to a temp file and pass `-d "$(cat body.md)"`.
