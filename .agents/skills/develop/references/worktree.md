# Worktree workflow — full detail

Develop every feature in its own **git worktree**, not in the main checkout. The one-line version lives in `SKILL.md`; this file has the rationale, the exact commands, and the verification caveats.

## Why

The main checkout at `~/.local/share/nvim/lazy/pi2.nvim` is a *live lazy.nvim plugin path* — the running Neovim loads its code, and it must stay on `main`. Creating or switching branches there:

- swaps the code under the **running editor** mid-session (lazy never hot-reloads, so the open nvim keeps the old modules while the files on disk change — see G21), and
- races with **any other session** touching the same directory (branch switches landing between your edits, uncommitted work stranded on the wrong branch).

A worktree gives your feature an isolated directory and branch while the main checkout stays put on `main`.

## Setup

Run from anywhere; `MAIN` stays on `main`.

```bash
MAIN=~/.local/share/nvim/lazy/pi2.nvim            # live plugin path — leave it on main
WT_ROOT=~/.local/share/pi.nvim-worktrees           # MUST be outside .../nvim/lazy (see below)
name=grep-quickfix                                 # short kebab name

git -C "$MAIN" fetch origin
git -C "$MAIN" worktree add "$WT_ROOT/$name" -b "feat/$name" origin/main
cd "$WT_ROOT/$name"
make test                                          # baseline, must be green
```

- Keep worktrees **outside** `~/.local/share/nvim/lazy/`. lazy.nvim treats every directory under `lazy/` as a plugin, so a worktree there would be loaded as a *second* pi plugin (duplicate modules, double autocmds).
- Base the branch on `origin/main` so you start from the released state.

## Verification in the worktree

Path resolution differs by layer (the trap is G23):

| Layer | In a worktree it exercises… |
|-------|------------------------------|
| `make test` (unit) | **the worktree** ✓ — `tests/minimal_init.lua` resolves the repo root from its own file path |
| Headless e2e with `-u tests/minimal_init.lua` | **the worktree** ✓ — same path-relative resolution |
| `make smoke` / GUI automation | **the MAIN checkout** ⚠ — these boot `~/.config/nvim/init.lua`, and lazy loads pi from its installed path, not your worktree |

So do feature verification with `make test` plus headless e2e scripts run under `-u tests/minimal_init.lua`. For smoke/GUI proof of the worktree code, either run it **after merging to `main`**, or temporarily point lazy at the worktree with an env-gated `dir` in the pi lazy spec (recipe in G23).

## Cleanup

Only after the human review is approved and the branch is merged. Do **not** remove the worktree while the PR is still under review — review rounds (`pr:changes-requested` → fix → re-push) happen inside it.

```bash
cd "$MAIN"
git merge --no-ff "feat/$name" && git push origin main
git worktree remove "$WT_ROOT/$name"     # refuses if dirty; use --force only once you've confirmed it's merged
git branch -d "feat/$name"
git push origin --delete "feat/$name"
git worktree prune                       # tidy metadata if a worktree dir was deleted by hand
git -C "$MAIN" status                   # confirm main checkout is clean and still on main
```
