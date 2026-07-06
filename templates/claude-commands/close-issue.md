---
description: Close work on the current Linear issue — validate, commit, push, open PR into dev, set Linear to In Review.
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__list_issue_statuses
---

Close the current feature branch and open a PR into `dev`. Steps in order; **stop on any failure** — never `--no-verify`, never `--amend` past a failed hook, never `git add -A`.

## 0. Pre-flight
- `git rev-parse --abbrev-ref HEAD`. Branch must match `^{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-\d+-(fix|bug|feature)-[a-z0-9-]+$` and not be `dev`/`main`. Extract `{{TEAM_KEY}}-<n>` and `<type>`.
- Show `git status`, `git log --oneline origin/dev..HEAD`, `git diff --stat origin/dev...HEAD`.

## 1. Uncommitted changes
- If clean, skip. Else show diff, propose specific files by path (never `git add -A`/`.`), flag sensitive files (`.env*`, `*secret*`, `*.pem`, `*.key`).

## 2. Validate
- `{{BUILD_CMD}}` — stop on failure. `{{LINT_CMD}}` — stop on failure.

## 3. Commit gate
- Stage the agreed files. Propose a message starting with `{{TEAM_KEY}}-<n>:` (English, ≤72-char title, imperative).
- Stop and ask via `AskUserQuestion`: "Run git commit?" — Yes / Edit / Cancel. On Yes, commit. If a hook fails, fix and make a NEW commit (never `--amend`/`--no-verify`).

## 4. Rebase onto origin/dev
- `git fetch origin` && `git rebase origin/dev`. On conflict, stop, list files, ask resolve/abort — never auto-resolve.
- On clean rebase, re-run `{{BUILD_CMD}}` and `{{LINT_CMD}}`; abort on failure.

## 5. Push gate
- If remote branch diverged (rebase rewrote history), flag that `--force-with-lease` is needed.
- Stop and ask via `AskUserQuestion`: "Run git push?" — Yes / Yes with --force-with-lease / Cancel. Never `--force`. Never push to `dev`/`main`.

## 6. Open PR
- `gh pr create --base dev --head <branch> --title "{{TEAM_KEY}}-<n>: <title>" --body "<summary>"`.
- Print the PR URL. Merging the PR into `dev` triggers the staging deploy workflow. The later `dev` → `main` merge (which triggers production) stays a deliberate manual action.

## 7. Linear → In Review
- Resolve "In Review" via `list_issue_statuses` (team `{{TEAM_NAME}}`), then `save_issue` with `id: "{{TEAM_KEY}}-<n>"`. Skip silently if already there; warn (don't undo the push) on failure.

## Hard rules
- Never `--force` (only `--force-with-lease` with explicit confirmation). Never `--no-verify`/`--amend`-past-hook. Never `git add -A`/`.`. Separate commit and push gates. Never push to `dev`/`main` directly.
