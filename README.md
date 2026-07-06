# init-2env

Source of truth for the `/init-2env` Claude Code command.

## What it does

`/init-2env` bootstraps a brand-new **Next.js + Convex** project from scratch,
in an empty directory, with a two-environment setup wired end to end:

- **Two persistent Convex production-type deployments** in one Convex
  project: `production` (tracks git `main`) and `staging` (tracks git `dev`).
- **A new GitHub repo** with `main` + `dev` branches and per-branch deploy CI
  (`.github/workflows/convex-deploy-prod.yml`, `convex-deploy-dev.yml`), plus
  the GitHub secrets and environments the workflows need.
- **Vercel or Netlify**, pre-configured with the right env vars per target and
  a `vercel.json` / `netlify.toml` build command, so Convex deploys happen
  automatically on every build — no manual dashboard step.
- **A new Linear team** (and project) for the app, plus `/issue` and
  `/close-issue` commands stamped into the new repo for a PR-based workflow
  that drives Linear issue status automatically.

The command runs one interview + a single confirmation gate ("Execute all"),
then executes Phase 2 autonomously. See `command/init-2env.md` for the full
step-by-step flow, and
`docs/superpowers/specs/2026-07-05-init-2env-convex-design.md` for the design
rationale.

## One-time prerequisites

`/init-2env` **detects** these but cannot perform them for you — Phase 0
(`scripts/preflight.sh`) checks them and stops with exactly what's missing:

- **GitHub**: `gh auth login` (checked via `gh auth status`).
- **Convex**: logged in (`npx convex` / `convex` CLI available) or a
  `CONVEX_DEPLOY_KEY` already exported.
- **Deploy host**: `VERCEL_TOKEN` exported (or `vercel login`) for Vercel —
  the default — or `netlify login` if you choose Netlify.
- **Linear**: `LINEAR_API_KEY` exported (required). The command creates the
  Linear team and project via the Linear GraphQL API using this key, so preflight
  blocks if it is missing. The read-only Linear MCP is still used for discovery
  (listing existing teams/projects) when available.

The command never logs you in on your behalf; it only checks and reports.

## Install

```bash
bash scripts/sync.sh
```

This copies `command/init-2env.md` to `~/.claude/commands/init-2env.md` and
prints that path. Then run `/init-2env` from any empty folder.

Re-run `bash scripts/sync.sh` any time you edit `command/init-2env.md` — it
overwrites the installed copy.

## Repo layout

```
command/        The orchestration command (command/init-2env.md).
templates/       Files stamped into the new project:
  github-workflows/   Convex deploy CI (dev → staging, main → production).
  claude-commands/     /issue and /close-issue, stamped into .claude/commands/.
  env/                 .env.example.
  CLAUDE.md            Project-level CLAUDE.md for the new repo.
  docs/                DEV-PROD-WORKFLOW.md.
scripts/         One script per responsibility (preflight, setup-convex,
                 create-github-repo, set-github-secrets, wire-vercel,
                 wire-netlify, sync) plus scripts/lib/stamp.sh.
tests/           Test harness (tests/run.sh) + one *_test.sh per component.
docs/            Spec, plan, and this repo's own validation docs.
```

## Tests and lint

```bash
bash tests/run.sh
shellcheck scripts/*.sh scripts/lib/*.sh
```

`tests/run.sh` runs every `tests/*_test.sh` and prints `ALL TESTS PASSED` when
green. shellcheck should produce no output.

## Docs

- Spec: `docs/superpowers/specs/2026-07-05-init-2env-convex-design.md`
- Plan: `docs/superpowers/plans/2026-07-05-init-2env-convex.md`
- Manual end-to-end validation: `docs/E2E-CHECKLIST.md`

## License

[MIT](LICENSE)
