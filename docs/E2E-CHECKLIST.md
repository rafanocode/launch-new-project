# `/init-2env` end-to-end checklist

> **This creates real, BILLABLE resources**: a GitHub repo, a Convex project
> with two deployments, a Vercel/Netlify project, and a Linear team. **Run
> this only against sandbox/throwaway accounts** you're happy to delete
> afterward — a scratch GitHub org, a scratch Convex account, a scratch
> Vercel/Netlify team, a scratch Linear workspace. Do not run this against
> production accounts.

This is a manual validation run, not an automated test. Use it after any
change to `command/init-2env.md` or the scripts it calls, before trusting the
command against a real project.

## Setup

1. Confirm sandbox credentials are active for GitHub, Convex, Vercel (or
   Netlify), and Linear — not your real accounts.
2. `bash scripts/sync.sh` to install the latest command.
3. `mkdir` an empty scratch directory and `cd` into it.
4. Run `/init-2env` and go through the interview. Pick a throwaway project
   name and Linear team key (e.g. `zzz-e2e-test`).
5. Confirm the plan at the "Execute all" gate and let Phase 2 run.

## Verify

### (a) GitHub repo — branches and workflows

- [ ] The new repo exists on GitHub with both `main` and `dev` branches.
- [ ] `.github/workflows/convex-deploy-prod.yml` and
      `.github/workflows/convex-deploy-dev.yml` are present on both branches.
- [ ] GitHub secrets `CONVEX_DEPLOY_KEY_PROD` and `CONVEX_DEPLOY_KEY_STAGING`
      exist (values not visible, but listed in repo Settings → Secrets).
- [ ] GitHub environments `production` and `staging` exist.

### (b) Convex project — two deployments

- [ ] The Convex dashboard shows one project with two production-type
      deployments: `production` and `staging`.
- [ ] Each deployment has its own URL and its own data (no shared state).

### (c) Push to `dev` deploys staging

- [ ] Make a trivial change on `dev` (e.g. touch `convex/schema.ts` with a
      no-op comment) and push.
- [ ] The `convex-deploy-dev.yml` workflow run succeeds in GitHub Actions.
- [ ] The **staging** Convex deployment shows the new deploy (check the
      dashboard's deployment history/timestamp).
- [ ] `main` is untouched — the **production** deployment does NOT show a new
      deploy from this push.

### (d) Vercel/Netlify env vars + build command

- [ ] The Vercel (or Netlify) project exists and is linked to the repo.
- [ ] `CONVEX_DEPLOY_KEY` is present per target (Vercel: production ← prod key,
      preview/development ← staging key; Netlify: production / deploy-preview /
      branch-deploy). `NEXT_PUBLIC_CONVEX_URL` is NOT stored — it is injected at
      build time by the build command below.
- [ ] `vercel.json` (or `netlify.toml`) exists at the project root with the
      Convex-aware build command:
      - Vercel: `"buildCommand": "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL"`
      - Netlify: `[build] command = "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL"`
- [ ] A deploy triggered from either `main` or `dev` actually runs that build
      command (check the deploy's build log) and succeeds.

### (e) Linear team/project + `/issue` and `/close-issue`

- [ ] A new Linear team exists with the confirmed key, and a project inside
      it named after the app.
- [ ] `.claude/commands/issue.md` and `.claude/commands/close-issue.md` exist
      in the new repo, stamped with the real `{{TEAM_KEY}}`/`{{TEAM_NAME}}`/
      `{{AUTHOR_PREFIX}}` (no unstamped `{{...}}` placeholders left).
- [ ] Create a throwaway issue in the new Linear team/project. Run
      `/issue <TEAM_KEY>-<n>` — it resolves "In Progress" via
      `list_issue_statuses` and sets the issue to it.
- [ ] Make a trivial commit, then run `/close-issue` — it resolves
      "In Review" via `list_issue_statuses`, opens a PR into `dev`, and sets
      the issue to "In Review".

## Teardown

- [ ] Delete the GitHub repo.
- [ ] Delete both Convex deployments / the Convex project.
- [ ] Delete the Vercel/Netlify project.
- [ ] Delete (or archive) the throwaway Linear team/project and issue.
