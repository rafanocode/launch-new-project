# Dev → Prod workflow ({{PROJECT_NAME}})

## Topology
- Supabase project slug `{{SUPABASE_PROJECT_SLUG}}`, either:
  - **Two projects** — `production` (git `main`, secret `SUPABASE_DB_URL_PROD`) and `staging` (git `dev`, secret `SUPABASE_DB_URL_STAGING`); or
  - **One project + persistent branch** — `production` is the project itself, `staging` is a persistent branch named `dev`.

## CI
- `.github/workflows/supabase-deploy-dev.yml`: push to `dev` (paths `supabase/migrations/**`) → `supabase db push` to staging.
- `.github/workflows/supabase-deploy-prod.yml`: push to `main` → `supabase db push` to production (`environment: production`).

## Day-to-day
1. `/issue {{TEAM_KEY}}-<n>` → branch off `dev`.
2. Build the change; for schema changes, `supabase migration new <name>` and edit the generated SQL in `supabase/migrations/`.
3. `/close-issue` → PR into `dev`.
4. Merge PR → staging migration runs automatically.
5. When staging looks good, merge `dev` → `main` → production migration runs.

## One-time setup (done by /init-2env)
- GitHub secret(s) `SUPABASE_DB_URL_STAGING` (if provisioned), `SUPABASE_DB_URL_PROD`; Environments `staging`, `production`.
- Vercel/Netlify env vars per context (see `.env.example`): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.

## If you chose "persistent branch" and it wasn't provisioned automatically
`/init-2env` attempts to create the `dev` persistent branch via the Supabase CLI. If that
didn't succeed (printed at the end of setup), connect this repo in Supabase → Settings →
Integrations → GitHub, then create the branch from the dashboard (or re-run
`supabase branches create dev --persistent --project-ref <your-project-ref>`), and set
`SUPABASE_DB_URL_STAGING` / the preview env vars by hand afterward.
