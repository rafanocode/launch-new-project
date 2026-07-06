# Dev → Prod workflow ({{PROJECT_NAME}})

## Topology
- One Convex project (`{{CONVEX_PROJECT_SLUG}}`), two production-type deployments:
  - `production` — git `main`, secret `CONVEX_DEPLOY_KEY_PROD`.
  - `staging` — git `dev`, secret `CONVEX_DEPLOY_KEY_STAGING`.

## CI
- `.github/workflows/convex-deploy-dev.yml`: push to `dev` (paths `convex/**`) → `npx convex deploy` to staging.
- `.github/workflows/convex-deploy-prod.yml`: push to `main` → deploy to production (`environment: production`).

## Day-to-day
1. `/issue {{TEAM_KEY}}-<n>` → branch off `dev`.
2. Build the change; edit `convex/schema.ts` for data-model changes (no migration files).
3. `/close-issue` → PR into `dev`.
4. Merge PR → staging deploy runs automatically.
5. When staging looks good, merge `dev` → `main` → production deploy runs.

## One-time setup (done by /init-2env)
- GitHub secrets `CONVEX_DEPLOY_KEY_STAGING`, `CONVEX_DEPLOY_KEY_PROD`; Environments `staging`, `production`.
- Vercel/Netlify env vars per context (see `.env.example`).
