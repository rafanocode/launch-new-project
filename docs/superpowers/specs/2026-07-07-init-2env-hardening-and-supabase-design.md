# Design — `/init-2env` hardening + Supabase as a second backend

**Date:** 2026-07-07
**Status:** Approved (brainstorming), pending implementation plan
**Owner:** Rafa

## 1. Problem & goal

Two independent problems, addressed together because both touch the same
provisioning scripts and are more efficient to land in one pass:

1. **Hardening.** A repo review found real correctness gaps in the current
   Convex-only implementation: silent failure swallowing in the deploy-host
   wiring scripts, a preflight check that can false-negative, missing team/org
   selection, and a minor CI asymmetry. None of these are architectural — they
   are bugs to fix in place.
2. **Multi-backend.** `/init-2env` currently hardcodes Convex as the database.
   Add **Supabase** as a selectable alternative, chosen in the Phase 1
   interview, with **two** sub-modes for environment isolation (the user
   explicitly wants both offered, not just the "correct" one):
   - **Two projects + SQL migrations** (recommended default for Supabase).
   - **Single project + persistent branch** (best-effort; Supabase's own
     model for one-project-multiple-environments).

Convex and Supabase are not interchangeable behind one interface — Convex is
schema-reconciled with no migrations; Supabase is Postgres with versioned SQL
migrations. The design introduces a **backend** dimension the rest of the
command is agnostic to, without pretending the two are the same shape
underneath.

## 2. Decisions locked in brainstorming

1. **Scope:** one combined plan/spec covering both the fixes and Supabase
   support (not two separate tracks).
2. **Supabase environment model:** offer **both** "two projects" and
   "persistent branch" at interview time — not just the recommended one.
3. **Phasing:** all of it (7 fixes + both Supabase modes) lands in a single
   implementation pass, not split into a later phase B.
4. **Persistent branch reality:** `supabase branches create --persistent
   --project-ref <ref>` is a real CLI/Management-API call (verified via
   `supabase branches create --help`, CLI v2.98.2) — it does **not**
   necessarily require the GitHub App to be connected in the dashboard first,
   but the docs don't confirm that either way. Resolution: **best-effort**.
   The script always does everything it can via CLI; if the branch-create
   call fails, this is **not fatal** — Phase 3 prints a single manual
   instruction (connect GitHub integration / create the branch by hand, then
   re-run). This is the same pattern already used for the Vercel/Netlify
   OAuth-connect friction point and for Linear team-creation plan limits.
5. **Convex `--team`**: fixed the same way Supabase's `--org-id` is handled —
   list and ask/require when ambiguous, rather than relying on interactive
   CLI prompts inside a non-interactive script.
6. **CI shape for Supabase:** one secret per environment holding a full
   Postgres connection string (`SUPABASE_DB_URL_PROD` /
   `SUPABASE_DB_URL_STAGING`), pushed with `supabase db push --db-url
   "$SUPABASE_DB_URL"`. No `supabase link`, no access token in CI. This
   mirrors the existing `CONVEX_DEPLOY_KEY_PROD`/`_STAGING` single-secret
   shape instead of inventing a new CI credential model.
7. **Scaffold for Supabase:** `npx create-next-app@latest -e with-supabase`
   (official Next.js + Supabase example), analogous to `npm create
   convex@latest -- -t nextjs` for Convex.
8. **No app-level Auth/RLS work in scope.** Same boundary as Convex mode
   today: the command wires infrastructure (project, migrations, CI, env
   vars), not application features. RLS/policies are the user's job once the
   project exists.

## 3. Part A — Fixes to the existing Convex-only implementation

These are bug fixes to code that already exists; no new architecture.

| # | File | Problem | Fix |
|---|---|---|---|
| 1 | `scripts/wire-vercel.sh`, `scripts/wire-netlify.sh` | Every external call uses `\|\| echo "...(continuing)"`; the script always exits 0, even on auth/network failure. Contradicts the design's own "exits non-zero on real failure" rule and the command's "never continue silently" hard rule. | Distinguish "resource already exists" (detectable, non-fatal — e.g. exit code / message pattern specific to "already exists") from any other failure (auth, network, invalid token), which must `exit 1` and print the real error. Add a test exercising the failure path (currently only the happy path is stubbed), for both scripts. |
| 2 | `scripts/preflight.sh` | Checks `command -v convex` (global binary), but the README says `npx convex` is sufficient. Blocks unnecessarily for users without a global install. | Check `command -v convex \|\| npx --no-install convex --version >/dev/null 2>&1`, matching what the rest of the command actually invokes. |
| 3 | `scripts/preflight.sh` | Vercel/Netlify checks only look for the binary, not a valid session/token — combined with fix #1's silent-continue bug, this can report "OK" and then fail invisibly in Phase 2 step 7. | Add a real auth check: `vercel whoami` (with `--token "$VERCEL_TOKEN"` if set) / `netlify status`, not just `command -v`. |
| 4 | `scripts/setup-convex.sh` | `convex project create` doesn't pass `--team`; if the account belongs to more than one team, the CLI prompts interactively — which hangs/fails when run non-interactively. No interview question exists to choose it. | Add `CONVEX_TEAM` support: if the account has exactly one team, use it silently; if more than one and `CONVEX_TEAM` isn't set, surface it as a Phase 1 interview question (mirrors the same "org-id" question added for Supabase in Part B). Pass `--team "$CONVEX_TEAM"` explicitly. |
| 5 | `templates/github-workflows/convex-deploy-prod.yml` vs `convex-deploy-dev.yml` | Prod workflow declares `environment: production`; dev workflow doesn't declare `environment: staging`, even though `set-github-secrets.sh` creates both GitHub Environments. Asymmetric without explanation. | Add `environment: staging` to `convex-deploy-dev.yml` for symmetry. |
| 6 | `scripts/wire-netlify.sh` | Deploy key passed as a positional arg to `netlify env:set` (visible in `ps`/shell history), because the Netlify CLI has no stdin option for this. | No code fix possible (CLI limitation) — already documented in a comment. Leave as is; no action needed beyond what's already there. |
| 7 | Repo-level CI | No CI in this repo running `tests/run.sh` + `shellcheck` on every change. | Out of scope for this pass (not something the original analysis asked to fix as a defect in the command's behavior) — noted, not actioned, unless requested separately. |

## 4. Part B — Supabase as a second backend

### 4.1 The `backend` dimension

Phase 1 interview gains a new question, asked right after project name:

> **Database:** Convex (default) / Supabase

If Supabase, a follow-up:

> **Environment isolation:** Two Supabase projects + SQL migrations
> (recommended) / Single project + persistent branch (best-effort)

This yields three concrete `backend` modes the rest of the flow branches on:
`convex`, `supabase-projects`, `supabase-branch`. Everything **not**
DB-specific (GitHub repo, Linear team, CI secrets/environments plumbing,
`/issue`+`/close-issue` templates) stays identical across all three.

### 4.2 Preflight (Phase 0)

If `backend` starts with `supabase`: check `supabase` CLI present and a valid
session (`supabase projects list` succeeds, or `SUPABASE_ACCESS_TOKEN` is
exported) — same shape as the existing `gh`/`vercel`/`convex` checks.

### 4.3 Provisioning (`scripts/setup-supabase.sh`, parallel to `setup-convex.sh`)

Single script, mode selected via `--mode projects|branch`:

**Common:**
- Resolve `--org-id` (list `supabase orgs list` if ambiguous — same pattern
  as the Convex `--team` fix in Part A).
- `--keys-file` contract identical to today: keys/URLs/connection strings
  written only there, umask 077, never to stdout; the file is the sole
  handoff to later steps (GitHub secrets, deploy-host wiring), deleted once
  by the orchestration at the end of Phase 2 (unchanged from today).

**Mode `projects` (two projects):**
1. `supabase projects create <slug>-prod --org-id ... --db-password ...`
   and `<slug>-staging`, idempotent (an "already exists" response is not
   fatal; any other failure is).
2. If `supabase/migrations/` doesn't exist yet in the scaffolded app, create
   it empty (the scaffold or the user supplies real migrations later — this
   command does not author schema).
3. For each project: `supabase projects api-keys --project-ref <ref>` →
   capture URL, anon key, service_role key; construct the pooler connection
   string for CI. Write `SUPABASE_URL_PROD`, `SUPABASE_ANON_KEY_PROD`,
   `SUPABASE_SERVICE_ROLE_KEY_PROD`, `SUPABASE_DB_URL_PROD` (and `_STAGING`
   equivalents) to the keys file.

**Mode `branch` (single project + persistent branch):**
1. `supabase projects create <slug> --org-id ... --db-password ...`
   (this project is production; `main`).
2. Attempt `supabase branches create dev --persistent --project-ref <ref>`.
   - **Success:** `supabase branches get dev --project-ref <ref>` for the
     branch's own ref/credentials; treat it exactly like the "staging"
     project above for key extraction.
   - **Failure:** non-fatal. Record in the keys file that staging
     provisioning did not complete; Phase 3 prints the manual instruction
     ("connect this repo in Supabase → Settings → Integrations → GitHub,
     then re-run `scripts/setup-supabase.sh --mode branch --resume`" — exact
     resume mechanics are an implementation-plan detail, not fixed here).

### 4.4 CI templates (`templates/github-workflows/supabase-deploy-{dev,prod}.yml`)

Same trigger shape as the Convex workflows (`on: push` to `dev`/`main`,
`paths: supabase/migrations/**`, `concurrency` group, `environment:`
staging/production for symmetry — this also closes fix #5 for the new
templates from day one). Body:

```yaml
- uses: supabase/setup-cli@v1
- run: supabase db push --db-url "$SUPABASE_DB_URL"
  env:
    SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL_STAGING }}  # or _PROD
```

No `supabase link`, no `SUPABASE_ACCESS_TOKEN` needed in CI — the full
connection string is the only credential, matching the single-secret shape
Convex already uses.

### 4.5 Deploy host wiring (`wire-vercel.sh` / `wire-netlify.sh`)

Both scripts gain a `--backend convex|supabase` switch (or read it from the
keys file, whichever the implementation plan finds cleaner) since the set of
env vars to write differs:

| Variable | Convex | Supabase |
|---|---|---|
| `CONVEX_DEPLOY_KEY` | prod/staging key per target | — |
| `NEXT_PUBLIC_SUPABASE_URL` | — | project/branch URL per target (public) |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | — | anon key per target (public) |
| `SUPABASE_SERVICE_ROLE_KEY` | — | service_role key per target (secret, server-only — only set if the scaffold's server code expects it) |

`CONVEX_DEPLOY_KEY` remains the only Convex var (URL is injected at build
time, unchanged). Supabase has no equivalent build-time injection trick — its
URL/anon key are stable per project and set directly as env vars, same as any
other Next.js public env var.

This is also where **fix #1** applies to the *new* Supabase code paths from
the start: every `vercel env add` / `netlify env:set` call here must
distinguish "already exists" from real failure, not silently continue.

### 4.6 Templates: conditional content by backend

`templates/CLAUDE.md` and `templates/docs/DEV-PROD-WORKFLOW.md` get a
backend-conditional section (stamped by the command, not by shell scripting —
same mechanism as today's `{{VAR}}` substitution, just choosing which block
of prose to keep):

- Convex block: existing text (schema reconciliation, no migrations).
- Supabase block: `supabase/migrations/`, `supabase migration new <name>` to
  create a migration, CI pushes on merge, local dev via `supabase start`.

`templates/env/.env.example` similarly gets a backend-specific variant.

### 4.7 Testing strategy

- `tests/setup_supabase_test.sh`: mirrors `tests/setup_convex_test.sh` — stub
  the `supabase` CLI (extend `tests/lib/with_stubs.sh`), cover both modes,
  cover the org-id-ambiguous path, cover the branch-create-fails-non-fatally
  path explicitly (this exact path has no equivalent test today for Convex
  and shouldn't be skipped here either).
- `tests/wire_vercel_test.sh` / `tests/wire_netlify_test.sh`: extend for the
  Supabase env-var set, and add the real-failure-exits-nonzero case demanded
  by fix #1 (applies to both backends).
- `tests/preflight_test.sh`: extend for the Supabase check and for fixes #2/#3.
- Template rendering tests (`tests/templates_*_test.sh`): extend to render
  the Supabase-conditional blocks and assert no leftover `{{VAR}}` markers.

### 4.8 `docs/E2E-CHECKLIST.md`

Add two new sections parallel to the existing Convex one: "Supabase (two
projects)" and "Supabase (persistent branch)", each verifying: projects/branch
exist, migrations apply via CI push to `dev`/`main`, `main` stays untouched by
a `dev` push, Vercel/Netlify env vars are correct per target, and — for the
branch mode specifically — one explicit checklist line for the best-effort
fallback ("if branch creation failed, confirm the manual instruction was
printed and following it manually completes provisioning").

## 5. Components & boundaries (updated)

- **`command/init-2env.md`** — gains the backend + isolation-mode interview
  questions and branches Phase 2 steps 1 (scaffold) and 2 (backend
  provisioning) on `backend`; steps 3–6 (GitHub, stamping, secrets, Linear)
  are unchanged in shape, just also handle the new Supabase secret names in
  step 5. Step 7 (deploy host) branches on `backend` for which env vars to
  set.
- **`scripts/setup-supabase.sh`** — new, same contract shape as
  `setup-convex.sh` (idempotent, single `--keys-file` output, exits non-zero
  on real failure, "already exists" is not fatal).
- **`scripts/wire-vercel.sh` / `wire-netlify.sh`** — extended, not replaced;
  backend-branching logic added alongside the fix-#1 error handling rewrite.
- **`templates/github-workflows/supabase-deploy-{dev,prod}.yml`** — new,
  same shape as the Convex pair.
- Everything Linear/GitHub-repo/Claude-commands-related is untouched — it
  was already backend-agnostic.

## 6. Out of scope

- Building actual Supabase Auth/RLS policies into the scaffold beyond what
  the official starter already includes.
- Supabase preview branches *per PR* (ephemeral, non-persistent) — only the
  persistent-branch mode is in scope, matching the "two fixed, long-lived
  environments" model the whole command is built around.
- CI for this orchestration repo itself (noted in Part A fix #7, not
  actioned).
- A generalized N-backend plugin system — three concrete modes are hardcoded
  branches, not an abstraction layer for hypothetical future backends.
