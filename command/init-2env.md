---
description: Bootstrap a brand-new Next.js+Convex project with two environments (main=prod, dev=staging), GitHub CI, Vercel/Netlify, and a Linear team. Usage: /init-2env
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__list_teams, mcp__plugin_linear_linear__list_projects, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Bootstrap a two-environment (main=production, dev=staging) Next.js + Convex project **from scratch** in the current empty directory. This repo's `scripts/` and `templates/` (path: the init-2env source repo — resolve it from where this command was synced, or ask) do the mechanical work.

Work top to bottom. There is exactly ONE confirmation gate (end of Phase 1). Preflight may stop earlier. On any Phase 2 failure, STOP, report what was created, and offer cleanup — never continue silently.

## Phase 0 — Preflight
- Run `scripts/preflight.sh --deploy <chosen>` (default vercel). If it exits non-zero, print the MISSING lines verbatim and STOP — tell the user exactly what to log in / export. Do not attempt logins yourself.

## Phase 1 — Interview + plan
Ask only what can't be inferred (use `AskUserQuestion`):
1. Project name → derive slug (kebab), repo name, Convex slug, Vercel/Netlify name, suggested Linear key (uppercase initials, e.g. "Maputo" → MAP).
2. GitHub repo private or public.
3. Deploy target: Vercel (default) or Netlify.
4. Confirm Linear team key and AUTHOR_PREFIX (initials from `git config user.name`).
Detect build/lint commands from the scaffold's `package.json` (default `npm run build` / `npm run lint`).

Print the FULL PLAN: repo (name+visibility), Convex project + `staging` deployment, GitHub secrets + environments, Linear team+project, deploy host + the exact env vars per target. Then ONE `AskUserQuestion`: **Execute all** / Edit / Cancel. Proceed only on "Execute all".

## Phase 2 — Autonomous execution (no further prompts)
1. **Scaffold**: run the official Next.js+Convex starter into the current dir (e.g. `npm create convex@latest -- -t nextjs` or the current recommended command — verify the flag with the starter's docs), then `git init` if needed and an initial commit.
2. **Convex**: `keys=$(mktemp)`; `scripts/setup-convex.sh <slug> --keys-file "$keys"`. This mints the prod+staging deploy keys and writes them only to `"$keys"` — this is the only place the keys file is created.
3. **GitHub**: `scripts/create-github-repo.sh <name> <vis>` → capture repo URL and `owner/repo`.
4. **Stamp templates** (export TEAM_KEY, TEAM_NAME, AUTHOR_PREFIX, PROJECT_NAME, BUILD_CMD, LINT_CMD, CONVEX_PROJECT_SLUG, then use `stamp_dir`/`stamp_file` from `scripts/lib/stamp.sh`):
   - `templates/github-workflows/*` → `.github/workflows/`
   - `templates/claude-commands/*` → `.claude/commands/`
   - `templates/CLAUDE.md` → `./CLAUDE.md`; `templates/docs/*` → `./docs/`; `templates/env/.env.example` → `./.env.example`
   - Commit the stamped files.
5. **Secrets**: `scripts/set-github-secrets.sh owner/repo "$keys"` — sets the two GitHub Actions secrets (`CONVEX_DEPLOY_KEY_PROD`, `CONVEX_DEPLOY_KEY_STAGING`) plus the `staging`/`production` GitHub environments. This step reads `"$keys"` but does NOT delete it — the deploy-host step (7) still needs it.
6. **Linear**: optionally discover existing teams first with `mcp__plugin_linear_linear__list_teams` (read-only). Then create the new team **via the Linear GraphQL API using LINEAR_API_KEY**: `curl -sS -X POST https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d '{"query":"mutation{ teamCreate(input:{name:\"<TEAM_NAME>\",key:\"<TEAM_KEY>\"}){ success team{ id name key } } }"}'` with the confirmed key; then create a project named after the app with the `projectCreate` mutation (passing the new team id in `teamIds`); note the returned ids/urls. If team creation fails (plan limit), STOP and offer "project inside an existing team" (list via `list_projects`).
7. **Deploy host**: `scripts/wire-vercel.sh <name> "$keys"` (or `wire-netlify.sh <site> "$keys"` for Netlify). This is the last consumer of `"$keys"` — after this step nothing else needs it. Alongside wiring, write the zero-touch build config so the Convex build command is set with no manual dashboard step. The build command injects `NEXT_PUBLIC_CONVEX_URL` at build time via `--cmd-url-env-var-name` (correct per environment because `CONVEX_DEPLOY_KEY` selects the deployment), so no URL env var is stored:
   - **Vercel**: write `vercel.json` at the project root:
     ```json
     { "buildCommand": "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL" }
     ```
   - **Netlify**: write `netlify.toml` at the project root with a `[build]` section:
     ```toml
     [build]
     command = "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL"
     publish = ".next"
     ```
   Commit `vercel.json` or `netlify.toml` together with the stamped files from step 4 (or in its own small commit if step 4 already ran) so the build command is live with no manual dashboard step.
8. **Cleanup**: `rm -f "$keys"` — delete the keys file now that both the GitHub secrets (step 5) and the deploy-host env vars (step 7) are set. This is the single point where the file is removed; no earlier step deletes it.

## Phase 3 — Summary
Print: repo URL, Convex production+staging dashboard URLs, Vercel/Netlify URL, Linear team+project URLs, and any single manual step left (e.g. connect the repo in the Vercel dashboard if OAuth was needed). Confirm nothing was pushed/charged beyond the approved plan.

## Hard rules
- One confirmation gate only; Preflight is the sole earlier stop. Never log in on the user's behalf. Never print or write secret values. On failure, stop + report + offer cleanup; never leave half-created resources silently.
