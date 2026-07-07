# {{PROJECT_NAME}}

## Environments
- `main` → Supabase **production** project (live). `dev` → Supabase **staging** project (or persistent branch — see `docs/DEV-PROD-WORKFLOW.md`). Never push directly to `dev` or `main`. Work on `{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-<n>-<type>-<short>` branches.

## Workflow
- Start work: `/issue {{TEAM_KEY}}-<n>`. Close work: `/close-issue` (opens a PR into `dev`).
- Merge PR → `dev`: CI pushes migrations to **staging**. Merge `dev` → `main`: CI pushes migrations to **production** (deliberate, manual merge).

## Backend (Supabase)
- Schema changes are versioned SQL migrations in `supabase/migrations/`. Create one with `supabase migration new <name>`, edit the generated SQL, commit it — CI applies it on merge (no schema reconciliation, unlike Convex).
- Local dev: `supabase start` (local Postgres + services), `supabase db push --local` to apply migrations locally.
- Project slug: `{{SUPABASE_PROJECT_SLUG}}`.

## Commands
- Build: `{{BUILD_CMD}}`  ·  Lint: `{{LINT_CMD}}`.
- All code and commit messages in English. Commit prefix `{{TEAM_KEY}}-<n>:` for Linear auto-link.
