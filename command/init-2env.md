---
description: Bootstrap a brand-new Next.js+Convex-or-Supabase project with two environments (main=prod, dev=staging), GitHub CI, Vercel/Netlify, and a Linear team. Usage: /init-2env
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__list_teams, mcp__plugin_linear_linear__list_projects, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Bootstrap a two-environment (main=production, dev=staging) Next.js + (Convex or Supabase) project **from scratch** in the current empty directory. This repo's `scripts/` and `templates/` (path: the init-2env source repo — resolve it from where this command was synced, or ask) do the mechanical work.

Work top to bottom. There is exactly ONE confirmation gate (end of Phase 1). Preflight may stop earlier. On any Phase 2 failure, STOP, report what was created, and offer cleanup — never continue silently.

## Phase 0 — Preflight
- Run `scripts/preflight.sh --deploy <chosen> --backend <chosen>` (deploy default vercel, backend default convex). If it exits non-zero, print the MISSING lines verbatim and STOP — tell the user exactly what to log in / export. Do not attempt logins yourself.

## Phase 1 — Interview + plan
Ask only what can't be inferred (use `AskUserQuestion`):
1. Project name → derive slug (kebab), repo name, backend project slug, Vercel/Netlify name, suggested Linear key (uppercase initials, e.g. "Maputo" → MAP).
2. **Database**: Convex (default) or Supabase.
   - If Supabase: **Environment isolation** — two Supabase projects + SQL migrations (recommended), or a single project + persistent branch (best-effort; may require a manual follow-up step if the CLI can't fully automate it — see Phase 3).
3. GitHub repo private or public.
4. Deploy target: Vercel (default) or Netlify.
5. Confirm Linear team key and AUTHOR_PREFIX (initials from `git config user.name`).
6. **Convex only**: if the account belongs to more than one Convex team (the user will know; there's no way to enumerate this via the CLI), ask for the team slug (`CONVEX_TEAM`). If they have only one team, skip this question — it's auto-detected.
7. **Supabase only**: run `supabase orgs list -o json` yourself right now (read-only, no side effects) to check org count — do this here, not in Phase 2, because Phase 2 has no further prompts and the full plan below needs to state which org will be used. If exactly one org, use it silently. If more than one, ask which org to use (`--org-id`); if zero, tell the user to create one first (same message `scripts/setup-supabase.sh` would give) and stop.

Detect build/lint commands from the scaffold's `package.json` (default `npm run build` / `npm run lint`).

Print the FULL PLAN: repo (name+visibility), backend resources (Convex project + staging deployment, or Supabase project(s)/branch), GitHub secrets + environments, Linear team+project, deploy host + the exact env vars per target. Then ONE `AskUserQuestion`: **Execute all** / Edit / Cancel. Proceed only on "Execute all".

## Phase 2 — Autonomous execution (no further prompts)
1. **Scaffold**:
   - Convex: run the official Next.js+Convex starter into the current dir (e.g. `npm create convex@latest -- -t nextjs` or the current recommended command — verify the flag with the starter's docs).
   - Supabase: run `npx create-next-app@latest -e with-supabase` into the current dir (verify the flag with the starter's docs).
   Then `git init` if needed and an initial commit.
2. **Backend provisioning**: `keys=$(mktemp)`.
   - Convex: `scripts/setup-convex.sh <slug> --keys-file "$keys" [--team <team>]`. Mints the prod+staging deploy keys, writes them only to `"$keys"`.
   - Supabase: `scripts/setup-supabase.sh <slug> --mode <projects|branch> --keys-file "$keys" [--org-id <id>]`. Creates the project(s)/branch, writes refs/URLs/publishable keys/db connection strings only to `"$keys"`. If mode is `branch` and staging provisioning was best-effort and didn't complete, this is **not fatal** — proceed, and note it for Phase 3's summary (the keys file records `SUPABASE_STAGING_PROVISIONED=no`).
   This is the only place the keys file is created.
3. **GitHub**: `scripts/create-github-repo.sh <name> <vis>` → capture repo URL and `owner/repo`.
4. **Stamp templates** (export TEAM_KEY, TEAM_NAME, AUTHOR_PREFIX, PROJECT_NAME, BUILD_CMD, LINT_CMD, and `CONVEX_PROJECT_SLUG` or `SUPABASE_PROJECT_SLUG` depending on backend, then use `stamp_dir`/`stamp_file` from `scripts/lib/stamp.sh`):
   - `templates/github-workflows/convex-deploy-{dev,prod}.yml` (Convex) or `templates/github-workflows/supabase-deploy-{dev,prod}.yml` (Supabase) → `.github/workflows/`.
   - `templates/claude-commands/*` → `.claude/commands/` (backend-agnostic, unchanged).
   - `templates/CLAUDE.md` (Convex) or `templates/CLAUDE.supabase.md` (Supabase) → `./CLAUDE.md`.
   - `templates/docs/DEV-PROD-WORKFLOW.md` (Convex) or `templates/docs/DEV-PROD-WORKFLOW.supabase.md` (Supabase) → `./docs/DEV-PROD-WORKFLOW.md`.
   - `templates/env/.env.example` (Convex) or `templates/env/.env.supabase.example` (Supabase) → `./.env.example`.
   - Commit the stamped files.
5. **Secrets**: `scripts/set-github-secrets.sh owner/repo "$keys" [backend]` — sets the backend's GitHub Actions secrets (Convex: `CONVEX_DEPLOY_KEY_PROD`/`_STAGING`; Supabase: `SUPABASE_DB_URL_PROD`/`_STAGING`, skipping the staging one if not provisioned) plus the `staging`/`production` GitHub environments. This step reads `"$keys"` but does NOT delete it — the deploy-host step (7) still needs it.
6. **Linear**: optionally discover existing teams first with `mcp__plugin_linear_linear__list_teams` (read-only). Then create the new team **via the Linear GraphQL API using LINEAR_API_KEY**: `curl -sS -X POST https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d '{"query":"mutation{ teamCreate(input:{name:\"<TEAM_NAME>\",key:\"<TEAM_KEY>\"}){ success team{ id name key } } }"}'` with the confirmed key; then create a project named after the app with the `projectCreate` mutation (passing the new team id in `teamIds`); note the returned ids/urls. If team creation fails (plan limit), STOP and offer "project inside an existing team" (list via `list_projects`).
7. **Deploy host**: `scripts/wire-vercel.sh <name> "$keys" [backend]` (or `wire-netlify.sh <site> "$keys" [backend]` for Netlify). `backend` defaults to `convex` when omitted; pass it explicitly for Supabase. This is the last consumer of `"$keys"` — after this step nothing else needs it.
   - **Convex**: write the zero-touch build config so the Convex build command is set with no manual dashboard step. The build command injects `NEXT_PUBLIC_CONVEX_URL` at build time via `--cmd-url-env-var-name` (correct per environment because `CONVEX_DEPLOY_KEY` selects the deployment), so no URL env var is stored:
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
   - **Supabase**: no build-command injection is needed — `NEXT_PUBLIC_SUPABASE_URL`/`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are plain, stable env vars set directly by `wire-vercel.sh`/`wire-netlify.sh`. Do not write a custom build command for Supabase; the framework preset's default build is enough.
   Commit `vercel.json`/`netlify.toml` (Convex only) together with the stamped files from step 4 (or in its own small commit if step 4 already ran) so the build command is live with no manual dashboard step.
8. **Cleanup**: `rm -f "$keys"` — delete the keys file now that both the GitHub secrets (step 5) and the deploy-host env vars (step 7) are set. This is the single point where the file is removed; no earlier step deletes it.

## Phase 3 — Summary
Print: repo URL, backend dashboard URL(s) (Convex production+staging, or the Supabase project(s)/branch), Vercel/Netlify URL, Linear team+project URLs, and any single manual step left (e.g. connect the repo in the Vercel dashboard if OAuth was needed). **If Supabase mode was `branch` and staging provisioning was best-effort and didn't complete**, print the manual follow-up: connect this repo in Supabase → Settings → Integrations → GitHub, create the persistent `dev` branch from the dashboard (or re-run `supabase branches create dev --persistent --project-ref <ref>`), then set `SUPABASE_DB_URL_STAGING` and the preview/development env vars by hand. Confirm nothing was pushed/charged beyond the approved plan.

## Hard rules
- One confirmation gate only; Preflight is the sole earlier stop. Never log in on the user's behalf. Never print or write secret values. On failure, stop + report + offer cleanup; never leave half-created resources silently.
- Convex: if the account has multiple teams, `CONVEX_TEAM` must be asked/set explicitly (no CLI-side team listing exists) — never let `convex project create` hit its interactive team prompt.
- Supabase: DB passwords are only capturable at project-creation time — never attempt to "resume" into an already-existing project by that name; stop and offer cleanup instead (`scripts/setup-supabase.sh` already enforces this).
