---
name: release
description: Cut a GitHub release for this Neovim plugin. Pick the next semver tag, build user-facing release notes (from CHANGELOG.md first, git log as fallback), confirm with the user, then publish and verify with the gh CLI. Use when the user asks to "make a release", "publish", or "tag a version".
---

# Release

Use this skill when the user wants to publish a GitHub release. `AGENTS.md` is the architecture charter; this skill is authoritative for the **release workflow**.

## Prerequisites

- `gh` CLI installed (Arch: `sudo pacman -S github-cli`) and authenticated:
  - `gh auth status` must show the account with the `repo` scope.
- Remote is `git@github.com:zgs225/pi2.nvim.git`; releases go to that repo.

## Workflow

1. Verify auth and inspect state:
   - `gh auth status`
   - `git tag --sort=-creatordate | head` and `gh release list --limit 5` — find the latest release.
   - `git status --short` and `git branch --show-current` — confirm a clean tree on `main`.
   - `git log --oneline -1` — the commit the tag will point at.
2. Determine the version with the user (do not assume):
   - First release: agree on a starting version (e.g. `v1.0.0`).
   - Subsequent releases: bump semver from the latest tag — `MAJOR` for breaking changes (`!` commits / `**BREAKING:**` changelog entries), `MINOR` for features, `PATCH` for fixes.
   - Confirm draft/prerelease status (default: normal release) and the target commit (default: latest `main`).
3. Build the release notes (see below). Show the draft to the user and get confirmation before publishing.
4. Write the confirmed notes to a temp file and publish:
   - `gh release create <tag> --target main --title "<tag>" --notes-file /tmp/<repo>-release-notes.md`
   - `gh release create` auto-creates **and pushes** the tag — no separate `git tag` / `git push --tags` needed.
5. Verify:
   - `gh release view <tag> --json tagName,name,isDraft,isPrerelease,targetCommitish,url`
   - Report the release URL.

## Release notes

`CHANGELOG.md` is the authoritative user-facing record — **draw notes from it first**, not from raw `git log`.

- Collect the changelog date sections accumulated since the previous release tag.
- Reorganize into themed groups (Prompt & input, Agent control, UI & rendering, Navigation & layout, Sessions & editor integration, Robustness, Developer infrastructure) rather than dumping date sections verbatim.
- Condense each entry to a single user-facing bullet; keep config keys, commands, and keymaps in backticks.
- Only fall back to `git log --oneline --no-merges` grouped by Conventional Commit type when there is no changelog coverage — and never list all commits for a large history.
- For the first release, frame what the project *is* (a short intro paragraph) before the highlights.
- End with a `**Full Changelog**:` link: `https://github.com/zgs225/pi2.nvim/commits/<tag>`.

Prefer user-facing framing over implementation detail — same rule as the `commit` skill.

## Output

When asked to release:
- state the proposed version, target commit, and draft/prerelease flags
- show the draft notes and wait for confirmation
- run `gh release create`
- report the created release URL and verified metadata

If the working tree is dirty or not on `main`, say so and resolve that before tagging.
