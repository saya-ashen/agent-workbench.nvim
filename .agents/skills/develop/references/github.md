# GitHub via gh CLI

Use authenticated `gh` commands for Agent Workbench repository operations. Repository: `saya-ashen/agent-workbench.nvim`.

## Authentication

```bash
gh auth status
```

The active account must have write access to the repository. Never print or embed the token.

## Issue and pull request lifecycle

| Action | Command |
| --- | --- |
| Create issue | `gh issue create -R saya-ashen/agent-workbench.nvim --title "<title>" --body-file <body.md>` |
| List issues | `gh issue list -R saya-ashen/agent-workbench.nvim` |
| Show issue | `gh issue view -R saya-ashen/agent-workbench.nvim <number>` |
| Comment | `gh issue comment -R saya-ashen/agent-workbench.nvim <number> --body-file <comment.md>` |
| Open PR | `gh pr create -R saya-ashen/agent-workbench.nvim --base main --head <branch> --title "<title>" --body-file <body.md>` |
| Check PR | `gh pr checks -R saya-ashen/agent-workbench.nvim <number>` |
| Merge PR | `gh pr merge -R saya-ashen/agent-workbench.nvim <number> --merge --delete-branch` |
| Close issue | `gh issue close -R saya-ashen/agent-workbench.nvim <number>` |

Issue body remains the spec. Put implementation progress in comments and pull requests. Link a PR with `Closes #<number>` when merge should close the issue.

## Actions

```bash
gh run list --repo saya-ashen/agent-workbench.nvim --branch main --limit 5
gh run view --repo saya-ashen/agent-workbench.nvim <run-id>
gh run view --repo saya-ashen/agent-workbench.nvim <run-id> --log-failed
```
