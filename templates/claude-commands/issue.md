---
description: Start work on a Linear issue — sync dev, create branch, set In Progress, initial analysis. Usage: /issue {{TEAM_KEY}}-52
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Start work on Linear issue **$ARGUMENTS**. Follow steps strictly in order; stop and surface any failure — never silently work around it.

## 0. Validate input
- If `$ARGUMENTS` is empty or doesn't match `{{TEAM_KEY}}-\d+`, stop and ask for a valid Linear ID.

## 1. Working tree must be clean
- `git status --porcelain`. If non-empty, stop and ask whether to stash/commit/abort.

## 2. Sync `dev`
- `git checkout dev` && `git pull origin dev --ff-only`. On failure, stop and surface it.

## 3. Fetch the Linear issue
- `mcp__plugin_linear_linear__get_issue` with `id: "$ARGUMENTS"`. If missing or not on team `{{TEAM_NAME}}`, stop.
- Read title, description, labels, state.

## 4. Decide branch type
- Inspect labels for `bug`/`feature`/`fix`. Exactly one → use it. Else ask via `AskUserQuestion`.

## 5. Build branch name
- Format `{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-<n>-<type>-<short>`; `<short>` = kebab of title, ≤5 words.
- Show it, confirm with a one-line `AskUserQuestion`, then `git checkout -b <branch>`.

## 6. Mark In Progress
- Resolve "In Progress" via `mcp__plugin_linear_linear__list_issue_statuses` (team `{{TEAM_NAME}}`), then `mcp__plugin_linear_linear__save_issue`. Skip silently if already there.

## 7. Initial analysis (no code)
Short written analysis (≤400 words): restate the task; prior-art search with Grep/Glob; read ≥1 implicated file end-to-end; proposed smallest change naming files; open questions. End: "Ready to start when you confirm the approach."

## Convex note
- This project uses **Convex**, not SQL migrations. Schema lives in `convex/schema.ts`; `npx convex deploy` reconciles it. There are **no migration files** — don't create any.

## Reminders
- Never `git commit`/`git push` here. Never merge to `dev`/`main`. All code/commits in English.
