# {{PROJECT_NAME}}

## Environments
- `main` → Convex **production** deployment (live). `dev` → Convex **staging** deployment (test). Both are persistent, same Convex project, identical schema.
- Never push directly to `dev` or `main`. Work on `{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-<n>-<type>-<short>` branches.

## Workflow
- Start work: `/issue {{TEAM_KEY}}-<n>`. Close work: `/close-issue` (opens a PR into `dev`).
- Merge PR → `dev`: CI deploys Convex to **staging**. Merge `dev` → `main`: CI deploys Convex to **production** (deliberate, manual merge).

## Backend (Convex)
- Schema: `convex/schema.ts`. Functions: `convex/*.ts`. Deploy reconciles schema — **no migration files**.
- Local dev: `npx convex dev` (personal dev deployment).

## Commands
- Build: `{{BUILD_CMD}}`  ·  Lint: `{{LINT_CMD}}`.
- All code and commit messages in English. Commit prefix `{{TEAM_KEY}}-<n>:` for Linear auto-link.
