# Design — `/init-2env` (Convex edition): bootstrap a 2-environment project from scratch

**Date:** 2026-07-05
**Status:** Approved (brainstorming), pending implementation plan
**Owner:** Rafa

## 1. Problem & goal

Provide a single Claude Code command, `/init-2env`, that bootstraps a **brand-new
project from zero** with two persistent environments (`main` = production, `dev` =
staging/test) and wires up everything needed to work like the WYK / qorum
projects — but on **Convex** instead of Supabase, and with as little manual input
from the user as possible ("do the minimum, ideally nothing").

Running it in an empty folder should, in a few minutes, produce:

- A running **Next.js + Convex** app (official starter).
- A new **GitHub repo** in the user's account with `main` + `dev` branches and CI
  that deploys to the right Convex deployment per branch.
- One **Convex project** with two persistent production-type deployments:
  `production` (↔ `main`) and `staging` (↔ `dev`).
- A **Vercel** (default) or **Netlify** project with all env vars pre-set per
  environment.
- A new **Linear team** + project, plus project-scoped `/issue` and
  `/close-issue` commands wired to it.

This **extends and replaces** the existing `~/.claude/commands/init-2env.md`
(which was Supabase-oriented and operated on an existing repo).

## 2. Decisions locked in brainstorming

1. **Database/backend:** Convex only (no Supabase).
2. **Distribution:** a **global command versioned in this repo** (`maputo`). We
   develop in `command/init-2env.md`; a `sync.sh` copies it to
   `~/.claude/commands/init-2env.md` (plain copy, not symlink).
3. **Scaffolding scope:** the command scaffolds a **real app** using the official
   Next.js + Convex starter, then layers infra on top.
4. **Linear:** create a **new team per project** (own key prefix, e.g. `MAP`),
   matching the current one-product-one-team pattern. Fall back to "project inside
   an existing team" only if team creation fails (plan limit).
5. **Autonomy:** **single confirmation at the start.** The command prints the full
   plan, one `AskUserQuestion` gate (Execute all / Edit / Cancel), then runs
   autonomously without further stops.
6. **Deploy target:** **Vercel** default; **Netlify** also supported at parity for
   the core path (site create + per-context env vars + build command). Chosen at
   runtime.
7. **Internal architecture:** **hybrid** — the markdown command does the smart /
   conversational work; deterministic mechanical work lives in versioned
   `templates/` (stamped with `{{VARS}}`) and `scripts/` (idempotent helpers).
8. **`/close-issue` merge model:** **PR-based** (`gh pr create --base dev`), which
   fits the automated CI. The `dev` → `main` merge (which triggers prod deploy)
   stays a deliberate user action.
9. **Convex preview deployments:** **out of v1** (future extension).
10. **Test-data seeding:** **out of v1** ("identical" means identical schema +
    functions, not data). Future extension via a seed mutation.

## 3. Repository layout (this repo = source of truth)

```
maputo/
├── command/
│   └── init-2env.md              # the command (source); synced to ~/.claude/commands/
├── templates/                    # assets the command stamps into the new project
│   ├── github-workflows/
│   │   ├── convex-deploy-dev.yml      # push dev  → convex deploy to staging deployment
│   │   └── convex-deploy-prod.yml     # push main → convex deploy to production deployment
│   ├── claude-commands/
│   │   ├── issue.md                   # parameterised: {{TEAM_KEY}}, {{AUTHOR_PREFIX}}, ...
│   │   └── close-issue.md
│   ├── env/
│   │   └── .env.example
│   ├── CLAUDE.md                      # base rules for the new project (dev/main flow, gates)
│   └── docs/
│       └── DEV-PROD-WORKFLOW.md
├── scripts/
│   ├── preflight.sh                   # detect gh/convex/vercel/netlify CLIs + tokens
│   ├── create-github-repo.sh
│   ├── setup-convex.sh                # project create + staging deployment + deploy keys
│   ├── wire-vercel.sh                 # create project, connect repo, set env vars
│   ├── wire-netlify.sh                # Netlify equivalent
│   ├── set-github-secrets.sh
│   └── sync.sh                        # copy command/init-2env.md → ~/.claude/commands/
├── docs/superpowers/specs/       # this design doc
└── README.md                     # what it is, one-time prerequisites, how to sync
```

Templates are real files with `{{VAR}}` markers; the command reads, substitutes,
and writes them into the target project so they can be reviewed/versioned apart
from the command.

## 4. Command flow

Runs in phases with exactly **one** gate (between phase 1 and 2).

### Phase 0 — Preflight (no side effects)
`scripts/preflight.sh` checks: `gh auth status`; `convex` CLI + login /
`CONVEX_DEPLOY_KEY`; `vercel` CLI + `VERCEL_TOKEN` (or `netlify` + token);
`LINEAR_API_KEY` or Linear MCP availability; and whether the current folder
already has git/`package.json`. If an **irreducible** prerequisite is missing,
stop and print exactly what to export/log in — the command never performs the
login itself. This is the only place it can stop before the plan.

### Phase 1 — Short interview + plan
Ask only what can't be inferred:
- Project name (derives slug, repo/Convex/Vercel names, suggested Linear key).
- GitHub repo private/public.
- Deploy target (default Vercel; Netlify option).
- Confirm Linear team key (e.g. `MAP`) and `AUTHOR_PREFIX` (from `git config
  user.name` initials).

Then print the **full plan** (resources + names + env vars to be set) and ask the
**single confirmation** (`AskUserQuestion`: Execute all / Edit / Cancel).

### Phase 2 — Autonomous execution (no further stops), ordered by dependency
1. Scaffold Next.js + Convex (official starter) → `git init`.
2. `setup-convex.sh`: create Convex project + `staging` deployment (prod-type) +
   deploy keys for both.
3. `create-github-repo.sh`: create repo, first commit, `main` + `dev` branches,
   push.
4. Stamp `templates/` → workflows, `.claude/commands/{issue,close-issue}.md`,
   `CLAUDE.md`, docs, `.env.example`.
5. `set-github-secrets.sh`: add Convex deploy keys as secrets
   (`CONVEX_DEPLOY_KEY_STAGING`, `CONVEX_DEPLOY_KEY_PROD`) + create GitHub
   Environments `staging` / `production`.
6. Linear: create new team + a project inside it; resolve `In Progress` / `In
   Review` state IDs.
7. `wire-vercel.sh` (or `wire-netlify.sh`): create project, connect repo, set env
   vars per environment.

### Phase 3 — Summary
Print URLs (repo, Convex prod/staging dashboards, Vercel/Netlify, Linear) and any
residual manual step (e.g. a single OAuth click if the deploy host required it).

### Error philosophy
If any Phase 2 step fails, **stop there**, report what was already created, and
explain how to resume. Never leave resources half-created silently or continue as
if nothing happened. On mid-run failure the command also offers (does not force)
to roll back / clean up what it just created.

## 5. Convex two-environment model & CI

One Convex project, two **persistent production-type** deployments:

| Environment | Convex deployment | Git branch | Deploys on |
|---|---|---|---|
| Production | `production` (project default) | `main` | push/merge to `main` |
| Staging/test | `staging` (`convex deployment create staging --type prod`) | `dev` | push/merge to `dev` |

Each has its own deploy keys and env vars. **"Identical" = identical schema +
functions** (same `convex/` deployed to both), **not data** — both start empty.

**CI workflows** (`templates/github-workflows/`):
- `convex-deploy-dev.yml` — `on: push: branches: [dev]`, `paths: convex/**`. Runs
  `npx convex deploy` with `CONVEX_DEPLOY_KEY=${{ secrets.CONVEX_DEPLOY_KEY_STAGING }}`.
- `convex-deploy-prod.yml` — `on: push: branches: [main]`, `paths: convex/**`.
  Same with `CONVEX_DEPLOY_KEY_PROD`, `environment: production` (reviewer optional,
  none in v1 per the autonomy decision).

YAML rules (inherited from qorum's solid pattern): `concurrency` groups,
`cancel-in-progress: false`, secrets in `env:` referenced as `"$VAR"`, `paths:`
filtered to `convex/**`. **No SQL migrations and no drift detection** — Convex
`deploy` reconciles the schema.

## 6. Vercel / Netlify wiring & env vars

`wire-vercel.sh`:
1. Create the Vercel project and connect the GitHub repo (`vercel` CLI/API +
   `VERCEL_TOKEN`); production branch = `main`, others = preview.
2. Build command: `npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL`
   (official Convex+Vercel pattern — deploys Convex and builds the frontend with
   the deployment URL injected into `NEXT_PUBLIC_CONVEX_URL` at build time).
3. Set env vars per target:

| Variable | production | preview / development |
|---|---|---|
| `CONVEX_DEPLOY_KEY` | production deployment key | staging deployment key |
| *(starter extras, if any)* | … | … |

`NEXT_PUBLIC_CONVEX_URL` is **not** a stored env var: it is injected at build
time by `--cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL`. The value is correct per
environment automatically because `CONVEX_DEPLOY_KEY` (set above) selects which
Convex deployment the build deploys to.

**Netlify** equivalent: `netlify sites:create`, `netlify env:set` per context
(`production` / `deploy-preview` / `branch-deploy`), analogous build command. Same
variable table.

**Friction point:** connecting the Git repo to Vercel/Netlify may need a one-time
OAuth authorization. If the token isn't enough, the command does **not** hang: it
leaves the project created with env vars set and prints the single remaining click.

Secrets are never written to files or printed.

## 7. Linear & project commands

**Creation (Phase 2, step 6):** create a new team with derived key (e.g. `MAP`),
create a project inside it, resolve `In Progress` / `In Review` state IDs for the
new team. Prefer Linear MCP; fall back to GraphQL API with `LINEAR_API_KEY`. If
team creation fails (plan limit), stop and offer "project inside an existing team".

**Templates `issue.md` / `close-issue.md`** (stamped into the new project's
`.claude/commands/`, parameterised with `{{TEAM_KEY}}`, `{{AUTHOR_PREFIX}}`,
`{{TEAM_NAME}}`, detected build/lint commands). Derived from qorum's versions,
adapted to Convex:

`/issue {{TEAM_KEY}}-NN`:
- Validate `^{{TEAM_KEY}}-\d+$`, clean tree, sync `dev`.
- Fetch Linear issue, pick type (fix/bug/feature) from labels, build branch
  `{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-NN-<type>-<short>`, set **In Progress**, initial
  analysis (no code).
- **Removed:** the whole Supabase migration block. Replaced with a light Convex
  note: "if you touch the schema, edit `convex/schema.ts`; deploy reconciles — no
  migration files."

`/close-issue`:
- Branch-taxonomy pre-flight; **separate** commit and push gates; `{{TEAM_KEY}}-NN:`
  commit prefix for Linear auto-link.
- Validate with detected `npm run build` / `lint`.
- **Removed:** all SQL migration drift detection.
- **PR-based:** `gh pr create --base dev`. Merge to `dev` triggers the staging
  deploy workflow; `dev` → `main` (prod) stays a deliberate user action.
- Set Linear to **In Review** + handoff.
- Keep qorum's hard rules: explicit per-gate confirmation, no `git add -A`, no
  `--force` (only `--force-with-lease`), no `--no-verify`, never push to dev/main
  directly.

## 8. Components & boundaries

- **`command/init-2env.md`** — orchestration + interview + plan + Linear via MCP +
  error handling. Depends on: scripts, templates, gh/convex/vercel CLIs, Linear MCP.
- **`scripts/*.sh`** — idempotent, single-purpose, fail-clean if the resource
  exists. Each takes explicit args, prints what it did, exits non-zero on real
  failure. Testable in isolation.
- **`templates/*`** — inert files with `{{VAR}}` markers. No logic.
- **`sync.sh`** — copies the command to `~/.claude/commands/`.

Each unit is understandable and changeable without reading the others' internals.

## 9. Testing strategy

- **Scripts:** dry-run flag where feasible; unit-test arg parsing and the
  fail-clean-on-existing behaviour. Lint with `shellcheck`.
- **Template stamping:** a test that renders each template with sample vars and
  asserts no `{{VAR}}` markers remain and the YAML/markdown is valid.
- **End-to-end (manual, gated):** one real run into a throwaway GitHub org / Convex
  team / Vercel scope, verifying the app deploys and both environments resolve.
  Documented as a checklist, not automated (creates billable resources).

## 10. Out of scope for v1 (future extensions)

- Convex preview deployments per branch.
- Test-data seeding mutation.
- Packaging as an installable Claude Code plugin/marketplace entry.
- Prod deploy approval gate (GitHub Environment reviewer).

## 11. One-time user prerequisites (the irreducible minimum)

The command detects and reports these but cannot perform them:
`gh` authenticated; Convex logged in or `CONVEX_DEPLOY_KEY` available;
`VERCEL_TOKEN` (or Netlify token); `LINEAR_API_KEY` or Linear MCP connected.
