# init-2env

Source of truth for the `/init-2env` Claude Code command, which bootstraps a
brand-new **Next.js + Convex or Supabase** project — from an empty directory
to a fully wired two-environment setup (staging + production) — in one run.

## Quick start

```bash
bash scripts/sync.sh
```

This copies `command/init-2env.md` to `~/.claude/commands/init-2env.md`.
Then, from any **empty** folder, run:

```
/init-2env
```

The command asks a short set of interview questions, shows you one
confirmation gate ("Execute all"), and then does everything else on its own.

Re-run `bash scripts/sync.sh` any time you edit `command/init-2env.md` — it
overwrites the installed copy.

## What it sets up

- **Two persistent deployments** — `production` (git `main`) and `staging`
  (git `dev`). For Convex: two deployments in one project. For Supabase: two
  separate projects, or one project with a persistent branch for staging.
- **A new GitHub repo** with `main` + `dev` branches, per-branch deploy CI
  (Convex deploys or Supabase migrations, depending on the backend you
  pick), and the GitHub secrets/environments those workflows need.
- **Vercel or Netlify**, pre-configured with the right env vars per
  environment and a build command that runs database updates automatically
  on every build — no manual dashboard step.
- **A new Linear team and project**, plus `/issue` and `/close-issue`
  commands stamped into the new repo, so a PR-based workflow drives Linear
  issue status automatically.

**Choosing a database:** Convex is the default. Supabase is also supported,
either as two separate projects with SQL migrations, or a single project
with a persistent staging branch (best-effort — if a manual follow-up step
is needed, it's printed at the end).

See `command/init-2env.md` for the full step-by-step flow, and
`docs/superpowers/specs/2026-07-05-init-2env-convex-design.md` for the design
rationale.

## One-time prerequisites

The command **checks** for these but can't set them up for you — Phase 0
(`scripts/preflight.sh`) stops early and tells you exactly what's missing.
It never logs you in on your behalf.

| Requirement | What's needed |
| --- | --- |
| `jq` | Installed — used by Supabase provisioning and the Netlify idempotency check. |
| GitHub | `gh auth login` (checked via `gh auth status`). |
| Convex (default database) | `npx convex`/`convex` CLI logged in, or `CONVEX_DEPLOY_KEY` exported. If your account has more than one Convex team, also export `CONVEX_TEAM` — the CLI can't list teams to auto-detect this. |
| Supabase (alternate database, chosen during the interview) | `supabase` CLI logged in, or `SUPABASE_ACCESS_TOKEN` exported. |
| Vercel (default deploy host) | `VERCEL_TOKEN` exported, or `vercel login`. |
| Netlify (alternate deploy host) | `NETLIFY_AUTH_TOKEN` exported, or `netlify login`. |
| Linear | `LINEAR_API_KEY` exported — required. The command uses it to create the Linear team/project via the GraphQL API; preflight blocks without it. The read-only Linear MCP is used for discovery (listing existing teams/projects) when available. |

## Repo layout

```
command/    The orchestration command (command/init-2env.md).
templates/  Files stamped into the new project:
  github-workflows/  Convex deploy CI or Supabase migration CI (dev → staging, main → production).
  claude-commands/   /issue and /close-issue, stamped into .claude/commands/ (backend-agnostic).
  env/               .env.example (Convex or Supabase variant).
  CLAUDE.md / CLAUDE.supabase.md  Project-level CLAUDE.md for the new repo, per backend.
  docs/              DEV-PROD-WORKFLOW.md (Convex or Supabase variant).
scripts/    One script per responsibility (preflight, setup-convex, setup-supabase,
            create-github-repo, set-github-secrets, wire-vercel, wire-netlify, sync)
            plus scripts/lib/stamp.sh.
tests/      Test harness (tests/run.sh) + one *_test.sh per component.
docs/       Spec, plan, and this repo's own validation docs.
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
