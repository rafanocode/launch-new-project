# `/init-2env` (Convex edition) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a global Claude Code command, `/init-2env`, that bootstraps a brand-new Next.js+Convex project with two persistent environments (`main`=production, `dev`=staging), a GitHub repo with per-branch deploy CI, a Vercel/Netlify project with env vars pre-set, a new Linear team, and PR-based `issue`/`close-issue` commands — all from an empty folder with a single confirmation.

**Architecture:** Hybrid. The markdown command (`command/init-2env.md`) does the conversational/adaptive work (interview, plan, Linear via MCP, error handling). Deterministic mechanical work lives in versioned `templates/` (inert files with `{{VAR}}` markers) and idempotent `scripts/*.sh` helpers. A pure-bash `stamp.sh` renders templates. This repo is the source of truth; `scripts/sync.sh` copies the command into `~/.claude/commands/`.

**Tech Stack:** Bash (helper scripts), Perl (marker substitution, universally available), `gh`, `convex`, `vercel`, `netlify` CLIs, Linear MCP/GraphQL, GitHub Actions YAML, Markdown (command + templates). Tests are plain-bash with PATH-stubbed CLIs + `shellcheck`.

## Global Constraints

- **Backend: Convex only.** One project, two production-type deployments: `production` (↔ `main`) and `staging` (↔ `dev`). Created with `npx convex deployment create staging --type prod`.
- **Single confirmation gate.** Preflight may stop before the plan; after the one "Execute all" gate, Phase 2 runs autonomously with no further prompts. On step failure it stops and reports.
- **Deploy target:** Vercel default, Netlify at parity for the core path. Chosen at runtime.
- **Linear:** new team per project (derived key, e.g. `MAP`); fall back to project-in-existing-team only if team creation fails.
- **`/close-issue`:** PR-based (`gh pr create --base dev`).
- **Secrets are never written to files or printed.** Deploy keys/tokens flow only into `gh secret set` / `vercel env` / `netlify env:set` via stdin.
- **Templates use `{{VAR}}` markers.** Stamped output MUST contain zero remaining `{{...}}` markers — `stamp_file` fails otherwise.
- **Scripts are idempotent and fail-clean:** re-running when a resource already exists must not error out the whole run; it detects "already exists" and continues.
- **All shell scripts must pass `shellcheck` with no errors.**
- **Out of v1:** Convex preview deployments, test-data seeding, plugin packaging, prod approval gate.
- **Commits:** the repo signs commits via SSH/1Password (`commit.gpgsign=true`) — 1Password must be unlocked when committing. Use plain `git commit` (signing is automatic).

---

### Task 1: Repo skeleton + test harness

**Files:**
- Create: `README.md`
- Create: `.gitignore`
- Create: `tests/lib/assert.sh`
- Create: `tests/lib/with_stubs.sh`
- Create: `tests/run.sh`
- Create: `templates/.gitkeep`, `scripts/lib/.gitkeep`

**Interfaces:**
- Produces: `assert_eq`, `assert_contains`, `assert_fail_exit`, test-registration convention; `make_stub <name> <body>` for PATH stubs; `tests/run.sh` runs every `tests/*_test.sh`.

- [ ] **Step 1: Create the assertion library**

`tests/lib/assert.sh`:
```bash
#!/usr/bin/env bash
# Tiny assertion helpers. Each increments FAILS on mismatch and prints context.
FAILS=0

assert_eq() { # <actual> <expected> <msg>
  if [ "$1" != "$2" ]; then
    echo "  FAIL: $3"; echo "    expected: [$2]"; echo "    actual:   [$1]"; FAILS=$((FAILS+1))
  else echo "  ok: $3"; fi
}

assert_contains() { # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) echo "  ok: $3" ;;
    *) echo "  FAIL: $3"; echo "    [$1] does not contain [$2]"; FAILS=$((FAILS+1)) ;;
  esac
}

assert_fail_exit() { # <exit_code> <msg>  — expects non-zero
  if [ "$1" -ne 0 ]; then echo "  ok: $2 (exit $1)"; else echo "  FAIL: $2 (expected non-zero, got 0)"; FAILS=$((FAILS+1)); fi
}
```

- [ ] **Step 2: Create the stub helper**

`tests/lib/with_stubs.sh`:
```bash
#!/usr/bin/env bash
# make_stub writes an executable fake CLI into $STUB_BIN (must be on PATH).
# Usage: make_stub gh 'echo "stub gh $*"; exit 0'
make_stub() { # <name> <body>
  local name="$1" body="$2"
  { echo '#!/usr/bin/env bash'; echo "$body"; } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}
```

- [ ] **Step 3: Create the test runner**

`tests/run.sh`:
```bash
#!/usr/bin/env bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ROOT
TOTAL_FAILS=0
for t in "$ROOT"/tests/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  STUB_BIN="$(mktemp -d)"; export STUB_BIN
  PATH="$STUB_BIN:$PATH" bash "$t"; rc=$?
  TOTAL_FAILS=$((TOTAL_FAILS+rc))
  rm -rf "$STUB_BIN"
done
if [ "$TOTAL_FAILS" -ne 0 ]; then echo "SUITE FAILED ($TOTAL_FAILS)"; exit 1; fi
echo "ALL TESTS PASSED"
```
Each `*_test.sh` must `exit "$FAILS"` at the end so the runner sums failures.

- [ ] **Step 4: Create `.gitignore` and README stub**

`.gitignore`:
```
.context/
*.log
.DS_Store
```

`README.md` (stub — finalized in Task 14):
```markdown
# init-2env

Source of truth for the `/init-2env` Claude Code command. See
`docs/superpowers/specs/2026-07-05-init-2env-convex-design.md`.
```

- [ ] **Step 5: Verify the harness runs green (empty suite)**

Run: `bash tests/run.sh`
Expected: `ALL TESTS PASSED` (no `*_test.sh` files yet).

- [ ] **Step 6: Commit**

```bash
git add README.md .gitignore tests templates/.gitkeep scripts/lib/.gitkeep
git commit -m "chore: repo skeleton and bash test harness"
```

---

### Task 2: `stamp.sh` template renderer

**Files:**
- Create: `scripts/lib/stamp.sh`
- Test: `tests/stamp_test.sh`

**Interfaces:**
- Produces: `stamp_file <template_path> <output_path>` — substitutes `{{VAR}}` from environment variables; returns non-zero and lists unresolved markers if any `{{...}}` remain. `stamp_dir <src_dir> <dest_dir>` — stamps every file under `src_dir` preserving relative paths.

- [ ] **Step 1: Write the failing test**

`tests/stamp_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"

tmp="$(mktemp -d)"
printf 'hello {{NAME}}, key={{TEAM_KEY}}\n' > "$tmp/in.txt"

# happy path
NAME="world" TEAM_KEY="MAP" stamp_file "$tmp/in.txt" "$tmp/out.txt"
assert_eq "$(cat "$tmp/out.txt")" "hello world, key=MAP" "substitutes all markers"

# missing var -> non-zero, marker preserved, listed on stderr
NAME="world" stamp_file "$tmp/in.txt" "$tmp/out2.txt" 2>"$tmp/err.txt"; rc=$?
assert_fail_exit "$rc" "fails when a marker is unresolved"
assert_contains "$(cat "$tmp/out2.txt")" "{{TEAM_KEY}}" "leaves unresolved marker in output"
assert_contains "$(cat "$tmp/err.txt")" "{{TEAM_KEY}}" "reports unresolved marker on stderr"

rm -rf "$tmp"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `scripts/lib/stamp.sh` not found / `stamp_file` not defined.

- [ ] **Step 3: Write minimal implementation**

`scripts/lib/stamp.sh`:
```bash
#!/usr/bin/env bash
# Render {{VAR}} markers from environment variables. Fails if any remain.
stamp_file() { # <template> <output>
  local tpl="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  perl -pe 's/\{\{(\w+)\}\}/exists $ENV{$1} ? $ENV{$1} : "{{$1}}"/ge' "$tpl" > "$out"
  if grep -q '{{[A-Za-z0-9_]\{1,\}}}' "$out"; then
    { echo "stamp: unresolved markers in $out:"; grep -o '{{[A-Za-z0-9_]\{1,\}}}' "$out" | sort -u; } >&2
    return 1
  fi
}

stamp_dir() { # <src_dir> <dest_dir>
  local src="$1" dest="$2" f rel
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    stamp_file "$f" "$dest/$rel" || return 1
  done < <(find "$src" -type f)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — all `stamp_test.sh` assertions ok.

- [ ] **Step 5: Lint**

Run: `shellcheck scripts/lib/stamp.sh`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/stamp.sh tests/stamp_test.sh
git commit -m "feat: stamp.sh template renderer with unresolved-marker guard"
```

---

### Task 3: `preflight.sh` prerequisite detection

**Files:**
- Create: `scripts/preflight.sh`
- Test: `tests/preflight_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/preflight.sh [--deploy vercel|netlify]` — prints one line per prerequisite as `OK <name>` or `MISSING <name>: <hint>`; exits non-zero if any **irreducible** prerequisite is missing. Checks: `gh` auth, `convex` CLI, deploy-host CLI (per `--deploy`, default vercel), Linear (`LINEAR_API_KEY` env OR file `~/.linear-mcp` marker — treated as soft, printed but not fatal since MCP may cover it).

- [ ] **Step 1: Write the failing test**

`tests/preflight_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

# All good: gh authed, convex present, vercel present
make_stub gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'
make_stub convex 'exit 0'
make_stub vercel 'exit 0'

out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel)"; rc=$?
assert_eq "$rc" "0" "exit 0 when all present"
assert_contains "$out" "OK gh" "reports gh ok"
assert_contains "$out" "OK convex" "reports convex ok"
assert_contains "$out" "OK vercel" "reports vercel ok"

# gh missing auth -> fatal
make_stub gh 'case "$1 $2" in "auth status") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when gh not authed"
assert_contains "$out" "MISSING gh" "reports gh missing with hint"

exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `preflight.sh` not found.

- [ ] **Step 3: Write minimal implementation**

`scripts/preflight.sh`:
```bash
#!/usr/bin/env bash
set -u
DEPLOY="vercel"
while [ $# -gt 0 ]; do case "$1" in --deploy) DEPLOY="$2"; shift 2;; *) shift;; esac; done

fatal=0
check() { # <name> <hint> ; runs following command via "$@" after first two args
  local name="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "OK $name"; else echo "MISSING $name: $hint"; fatal=1; fi
}

check gh "run: gh auth login" gh auth status
check convex "run: npm i -g convex (or npx convex)" command -v convex
if [ "$DEPLOY" = "netlify" ]; then
  check netlify "run: npm i -g netlify-cli && netlify login" command -v netlify
else
  check vercel "set VERCEL_TOKEN or run: vercel login" command -v vercel
fi

# Linear is soft: MCP may provide it. Report but do not fail.
if [ -n "${LINEAR_API_KEY:-}" ]; then echo "OK linear (LINEAR_API_KEY)"; else echo "SOFT linear: no LINEAR_API_KEY — relying on Linear MCP"; fi

exit "$fatal"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `shellcheck scripts/preflight.sh`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight.sh tests/preflight_test.sh
git commit -m "feat: preflight prerequisite detection"
```

---

### Task 4: Convex deploy workflow templates + `.env.example`

**Files:**
- Create: `templates/github-workflows/convex-deploy-dev.yml`
- Create: `templates/github-workflows/convex-deploy-prod.yml`
- Create: `templates/env/.env.example`
- Test: `tests/templates_workflows_test.sh`

**Interfaces:**
- Consumes: `stamp_file` (Task 2).
- Produces: rendered workflow YAML files; markers used: none required for workflows (they reference GitHub secrets literally). `.env.example` uses `{{CONVEX_PROJECT_SLUG}}`.

- [ ] **Step 1: Write the failing test**

`tests/templates_workflows_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"

CONVEX_PROJECT_SLUG="acme" stamp_dir "$ROOT/templates/env" "$tmp/env"
assert_eq "$?" "0" "env template stamps with no leftover markers"

# Workflows contain no {{ }} markers and reference the two secrets
for f in convex-deploy-dev.yml convex-deploy-prod.yml; do
  stamp_file "$ROOT/templates/github-workflows/$f" "$tmp/$f"
  assert_eq "$?" "0" "$f stamps clean"
done
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "CONVEX_DEPLOY_KEY_STAGING" "dev workflow uses staging key"
assert_contains "$(cat "$tmp/convex-deploy-prod.yml")" "CONVEX_DEPLOY_KEY_PROD" "prod workflow uses prod key"
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "branches: [dev]" "dev workflow triggers on dev"
assert_contains "$(cat "$tmp/convex-deploy-prod.yml")" "branches: [main]" "prod workflow triggers on main"
rm -rf "$tmp"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — template files not found.

- [ ] **Step 3: Create the workflow templates**

`templates/github-workflows/convex-deploy-dev.yml`:
```yaml
name: Convex Deploy (staging)

on:
  push:
    branches: [dev]
    paths:
      - 'convex/**'
      - 'package.json'
      - '.github/workflows/convex-deploy-dev.yml'
  workflow_dispatch:

concurrency:
  group: convex-deploy-staging
  cancel-in-progress: false

jobs:
  deploy:
    name: Deploy to staging deployment
    runs-on: ubuntu-latest
    env:
      CONVEX_DEPLOY_KEY: ${{ secrets.CONVEX_DEPLOY_KEY_STAGING }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Verify deploy key present
        run: |
          if [ -z "$CONVEX_DEPLOY_KEY" ]; then
            echo "::error::Missing secret CONVEX_DEPLOY_KEY_STAGING"; exit 1
          fi
      - run: npm ci
      - name: Deploy Convex (staging)
        run: npx convex deploy -y
```

`templates/github-workflows/convex-deploy-prod.yml`:
```yaml
name: Convex Deploy (production)

on:
  push:
    branches: [main]
    paths:
      - 'convex/**'
      - 'package.json'
      - '.github/workflows/convex-deploy-prod.yml'
  workflow_dispatch:

concurrency:
  group: convex-deploy-production
  cancel-in-progress: false

jobs:
  deploy:
    name: Deploy to production deployment
    runs-on: ubuntu-latest
    environment: production
    env:
      CONVEX_DEPLOY_KEY: ${{ secrets.CONVEX_DEPLOY_KEY_PROD }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Verify deploy key present
        run: |
          if [ -z "$CONVEX_DEPLOY_KEY" ]; then
            echo "::error::Missing secret CONVEX_DEPLOY_KEY_PROD"; exit 1
          fi
      - run: npm ci
      - name: Deploy Convex (production)
        run: npx convex deploy -y
```

- [ ] **Step 4: Create `.env.example`**

`templates/env/.env.example`:
```
# Convex project: {{CONVEX_PROJECT_SLUG}}
# Frontend URL is injected at build time by `npx convex deploy --cmd`.
# Local dev uses your personal dev deployment (npx convex dev).
NEXT_PUBLIC_CONVEX_URL=
# CI/CD deploy keys live in GitHub Secrets / Vercel env, never here:
#   CONVEX_DEPLOY_KEY_STAGING  (staging deployment)
#   CONVEX_DEPLOY_KEY_PROD     (production deployment)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS. During implementation, verify `npx convex deploy -y` is the correct non-interactive flag via `npx convex deploy --help`; adjust if the CLI uses a different confirm flag.

- [ ] **Step 6: Commit**

```bash
git add templates/github-workflows templates/env tests/templates_workflows_test.sh
git commit -m "feat: Convex deploy workflow templates and .env.example"
```

---

### Task 5: `issue` / `close-issue` command templates

**Files:**
- Create: `templates/claude-commands/issue.md`
- Create: `templates/claude-commands/close-issue.md`
- Test: `tests/templates_commands_test.sh`

**Interfaces:**
- Consumes: `stamp_file` (Task 2).
- Produces: rendered command markdown. Markers: `{{TEAM_KEY}}`, `{{TEAM_NAME}}`, `{{AUTHOR_PREFIX}}`, `{{BUILD_CMD}}`, `{{LINT_CMD}}`.

- [ ] **Step 1: Write the failing test**

`tests/templates_commands_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"

export TEAM_KEY="MAP" TEAM_NAME="Maputo" AUTHOR_PREFIX="RR" BUILD_CMD="npm run build" LINT_CMD="npm run lint"
stamp_dir "$ROOT/templates/claude-commands" "$tmp/cmds"
assert_eq "$?" "0" "command templates stamp with no leftover markers"

issue="$(cat "$tmp/cmds/issue.md")"
assert_contains "$issue" 'MAP-\d+' "issue.md uses derived team key in the ID regex"
assert_contains "$issue" "RR-MAP" "issue.md uses author+team prefix in branch format"
assert_contains "$issue" "convex/schema.ts" "issue.md has Convex schema note (not Supabase)"

close="$(cat "$tmp/cmds/close-issue.md")"
assert_contains "$close" "gh pr create --base dev" "close-issue is PR-based"
assert_contains "$close" "npm run build" "close-issue uses detected build command"
case "$close" in *"migration"*|*"Supabase"*) echo "  FAIL: close-issue still mentions migrations/Supabase"; FAILS=$((FAILS+1));; *) echo "  ok: no SQL-migration leftovers";; esac
rm -rf "$tmp"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — command templates not found.

- [ ] **Step 3: Create `issue.md` template**

`templates/claude-commands/issue.md` (adapted from an earlier project, Convex-ified):
````markdown
---
description: Start work on a Linear issue — sync dev, create branch, set In Progress, initial analysis. Usage: /issue {{TEAM_KEY}}-52
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Start work on Linear issue **$ARGUMENTS**. Follow steps strictly in order; stop and surface any failure — never silently work around it.

## 0. Validate input
- If `$ARGUMENTS` is empty or doesn't match `{{TEAM_KEY}}-\d+`, stop and ask for a valid Linear ID.

## 1. Working tree must be clean
- `git status --porcelain`. If non-empty, stop and ask whether to stash/commit/abort.

## 2. Sync `dev`
- `git checkout dev` && `git pull origin dev --ff-only`. On failure, stop and surface it.

## 3. Fetch the Linear issue
- `mcp__plugin_linear_linear__get_issue` with `id: "$ARGUMENTS"`. If missing or not on team `{{TEAM_NAME}}`, stop.
- Read title, description, labels, state.

## 4. Decide branch type
- Inspect labels for `bug`/`feature`/`fix`. Exactly one → use it. Else ask via `AskUserQuestion`.

## 5. Build branch name
- Format `{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-<n>-<type>-<short>`; `<short>` = kebab of title, ≤5 words.
- Show it, confirm with a one-line `AskUserQuestion`, then `git checkout -b <branch>`.

## 6. Mark In Progress
- Resolve "In Progress" via `mcp__plugin_linear_linear__list_issue_statuses` (team `{{TEAM_NAME}}`), then `mcp__plugin_linear_linear__save_issue`. Skip silently if already there.

## 7. Initial analysis (no code)
Short written analysis (≤400 words): restate the task; prior-art search with Grep/Glob; read ≥1 implicated file end-to-end; proposed smallest change naming files; open questions. End: "Ready to start when you confirm the approach."

## Convex note
- This project uses **Convex**, not SQL migrations. Schema lives in `convex/schema.ts`; `npx convex deploy` reconciles it. There are **no migration files** — don't create any.

## Reminders
- Never `git commit`/`git push` here. Never merge to `dev`/`main`. All code/commits in English.
````

- [ ] **Step 4: Create `close-issue.md` template**

`templates/claude-commands/close-issue.md`:
````markdown
---
description: Close work on the current Linear issue — validate, commit, push, open PR into dev, set Linear to In Review.
allowed-tools: Bash, Read, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__get_issue, mcp__plugin_linear_linear__save_issue, mcp__plugin_linear_linear__list_issue_statuses
---

Close the current feature branch and open a PR into `dev`. Steps in order; **stop on any failure** — never `--no-verify`, never `--amend` past a failed hook, never `git add -A`.

## 0. Pre-flight
- `git rev-parse --abbrev-ref HEAD`. Branch must match `^{{AUTHOR_PREFIX}}-{{TEAM_KEY}}-\d+-(fix|bug|feature)-[a-z0-9-]+$` and not be `dev`/`main`. Extract `{{TEAM_KEY}}-<n>` and `<type>`.
- Show `git status`, `git log --oneline origin/dev..HEAD`, `git diff --stat origin/dev...HEAD`.

## 1. Uncommitted changes
- If clean, skip. Else show diff, propose specific files by path (never `git add -A`/`.`), flag sensitive files (`.env*`, `*secret*`, `*.pem`, `*.key`).

## 2. Validate
- `{{BUILD_CMD}}` — stop on failure. `{{LINT_CMD}}` — stop on failure.

## 3. Commit gate
- Stage the agreed files. Propose a message starting with `{{TEAM_KEY}}-<n>:` (English, ≤72-char title, imperative).
- Stop and ask via `AskUserQuestion`: "Run git commit?" — Yes / Edit / Cancel. On Yes, commit. If a hook fails, fix and make a NEW commit (never `--amend`/`--no-verify`).

## 4. Rebase onto origin/dev
- `git fetch origin` && `git rebase origin/dev`. On conflict, stop, list files, ask resolve/abort — never auto-resolve.
- On clean rebase, re-run `{{BUILD_CMD}}` and `{{LINT_CMD}}`; abort on failure.

## 5. Push gate
- If remote branch diverged (rebase rewrote history), flag that `--force-with-lease` is needed.
- Stop and ask via `AskUserQuestion`: "Run git push?" — Yes / Yes with --force-with-lease / Cancel. Never `--force`. Never push to `dev`/`main`.

## 6. Open PR
- `gh pr create --base dev --head <branch> --title "{{TEAM_KEY}}-<n>: <title>" --body "<summary>"`.
- Print the PR URL. Merging the PR into `dev` triggers the staging deploy workflow. The later `dev` → `main` merge (which triggers production) stays a deliberate manual action.

## 7. Linear → In Review
- Resolve "In Review" via `list_issue_statuses` (team `{{TEAM_NAME}}`), then `save_issue` with `id: "{{TEAM_KEY}}-<n>"`. Skip silently if already there; warn (don't undo the push) on failure.

## Hard rules
- Never `--force` (only `--force-with-lease` with explicit confirmation). Never `--no-verify`/`--amend`-past-hook. Never `git add -A`/`.`. Separate commit and push gates. Never push to `dev`/`main` directly.
````

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add templates/claude-commands tests/templates_commands_test.sh
git commit -m "feat: parameterised issue/close-issue command templates (Convex, PR-based)"
```

---

### Task 6: `CLAUDE.md` + workflow doc templates

**Files:**
- Create: `templates/CLAUDE.md`
- Create: `templates/docs/DEV-PROD-WORKFLOW.md`
- Test: `tests/templates_docs_test.sh`

**Interfaces:**
- Consumes: `stamp_file`.
- Produces: rendered project `CLAUDE.md` and workflow doc. Markers: `{{PROJECT_NAME}}`, `{{TEAM_KEY}}`, `{{AUTHOR_PREFIX}}`, `{{BUILD_CMD}}`, `{{LINT_CMD}}`, `{{CONVEX_PROJECT_SLUG}}`.

- [ ] **Step 1: Write the failing test**

`tests/templates_docs_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"
export PROJECT_NAME="Maputo" TEAM_KEY="MAP" AUTHOR_PREFIX="RR" BUILD_CMD="npm run build" LINT_CMD="npm run lint" CONVEX_PROJECT_SLUG="maputo"
stamp_file "$ROOT/templates/CLAUDE.md" "$tmp/CLAUDE.md"; assert_eq "$?" "0" "CLAUDE.md stamps clean"
stamp_dir "$ROOT/templates/docs" "$tmp/docs"; assert_eq "$?" "0" "workflow doc stamps clean"
assert_contains "$(cat "$tmp/CLAUDE.md")" "dev" "CLAUDE.md documents dev/main flow"
assert_contains "$(cat "$tmp/docs/DEV-PROD-WORKFLOW.md")" "staging" "workflow doc explains staging deployment"
rm -rf "$tmp"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — templates not found.

- [ ] **Step 3: Create `templates/CLAUDE.md`**

```markdown
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
```

- [ ] **Step 4: Create `templates/docs/DEV-PROD-WORKFLOW.md`**

```markdown
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add templates/CLAUDE.md templates/docs tests/templates_docs_test.sh
git commit -m "feat: project CLAUDE.md and dev/prod workflow doc templates"
```

---

### Task 7: `setup-convex.sh`

**Files:**
- Create: `scripts/setup-convex.sh`
- Test: `tests/setup_convex_test.sh`

**Interfaces:**
- Consumes: `convex` CLI.
- Produces: `scripts/setup-convex.sh <project-slug>` — creates the Convex project (idempotent: reuse if exists), creates the `staging` prod-type deployment (idempotent), mints deploy keys for `prod` and `staging`. Writes the two keys to fd 3 as `PROD_KEY=<v>` / `STAGING_KEY=<v>` if fd 3 is open, else to a `--keys-file <path>` given by the caller (never stdout). Prints only status lines (no secrets) to stdout. Exit non-zero on real failure.

- [ ] **Step 1: Write the failing test**

`tests/setup_convex_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

# Stub convex: project create says "already exists" (idempotency), deployment create ok, token create prints a fake key
make_stub convex '
case "$1 $2" in
  "project create") echo "project already exists" >&2; exit 1;;
  "deployment create") echo "created"; exit 0;;
  "deployment token") echo "prod_or_staging_key_ABC"; exit 0;;
  *) exit 0;;
esac'

keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-convex.sh" acme --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds even when project already exists (idempotent)"
assert_contains "$out" "staging" "reports staging deployment step"
# secrets go to the keys file, never to stdout
case "$out" in *prod_or_staging_key_ABC*) echo "  FAIL: key leaked to stdout"; FAILS=$((FAILS+1));; *) echo "  ok: no key on stdout";; esac
assert_contains "$(cat "$keys")" "PROD_KEY=" "writes PROD_KEY to keys file"
assert_contains "$(cat "$keys")" "STAGING_KEY=" "writes STAGING_KEY to keys file"
rm -f "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write implementation**

`scripts/setup-convex.sh`:
```bash
#!/usr/bin/env bash
set -u
SLUG="${1:?usage: setup-convex.sh <slug> --keys-file <path>}"; shift
KEYS_FILE=""
while [ $# -gt 0 ]; do case "$1" in --keys-file) KEYS_FILE="$2"; shift 2;; *) shift;; esac; done
[ -n "$KEYS_FILE" ] || { echo "setup-convex: --keys-file required" >&2; exit 2; }

# 1. Project (idempotent: a non-zero "already exists" is not fatal)
echo "convex: ensuring project $SLUG"
convex project create "$SLUG" >/dev/null 2>&1 || echo "convex: project exists or already created, continuing"

# 2. Staging prod-type deployment (idempotent)
echo "convex: ensuring staging deployment"
convex deployment create staging --type prod >/dev/null 2>&1 || echo "convex: staging exists, continuing"

# 3. Deploy keys — captured, never printed
echo "convex: minting deploy keys"
prod_key="$(convex deployment token create ci-prod --deployment prod 2>/dev/null | tail -n1)"
staging_key="$(convex deployment token create ci-staging --deployment staging 2>/dev/null | tail -n1)"
[ -n "$prod_key" ] && [ -n "$staging_key" ] || { echo "convex: failed to mint deploy keys" >&2; exit 1; }

umask 077
{ echo "PROD_KEY=$prod_key"; echo "STAGING_KEY=$staging_key"; } > "$KEYS_FILE"
echo "convex: setup complete (keys written to keys file)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS. During implementation, verify exact flags for `convex deployment create` / `convex deployment token create` against `npx convex deployment --help` and the Platform APIs docs; adjust deployment-name selectors (`--deployment prod` vs the real prod name) if needed.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/setup-convex.sh` (clean), then:
```bash
git add scripts/setup-convex.sh tests/setup_convex_test.sh
git commit -m "feat: setup-convex.sh (project + staging deployment + deploy keys)"
```

---

### Task 8: `create-github-repo.sh`

**Files:**
- Create: `scripts/create-github-repo.sh`
- Test: `tests/create_github_repo_test.sh`

**Interfaces:**
- Consumes: `gh`, `git`.
- Produces: `scripts/create-github-repo.sh <name> <private|public>` — creates the repo under the authed account (idempotent: reuse if exists), ensures the local repo has an `origin`, creates `main` and `dev` branches, pushes both. Prints the repo URL (via `gh repo view --json url -q .url`).

- [ ] **Step 1: Write the failing test**

`tests/create_github_repo_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

work="$(mktemp -d)"; cd "$work" || exit 1
git init -q; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init

make_stub gh '
case "$1 $2" in
  "repo create") echo "created"; exit 0;;
  "repo view") echo "https://github.com/me/acme"; exit 0;;
  *) exit 0;;
esac'
make_stub git "$(printf 'exec %s/git.real "$@"' "$STUB_BIN")"  # not used; real git via PATH below

# Use real git for local ops but stubbed gh; put real git first is fine since we only stub gh.
out="$(bash "$ROOT/scripts/create-github-repo.sh" acme private)"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$out" "github.com/me/acme" "prints repo URL"
assert_contains "$(git branch --list dev)" "dev" "creates dev branch"
cd /; rm -rf "$work"
exit "$FAILS"
```
Note: remove the unused `git` stub line if it interferes; the test only needs a stubbed `gh`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write implementation**

`scripts/create-github-repo.sh`:
```bash
#!/usr/bin/env bash
set -u
NAME="${1:?usage: create-github-repo.sh <name> <private|public>}"
VIS="${2:-private}"

# 1. Ensure remote repo (idempotent)
if gh repo view "$NAME" >/dev/null 2>&1; then
  echo "gh: repo $NAME exists, reusing"
else
  gh repo create "$NAME" "--$VIS" --source=. --remote=origin --push=false >/dev/null 2>&1 \
    || { echo "gh: repo create failed" >&2; exit 1; }
  echo "gh: repo $NAME created"
fi

# 2. Ensure origin points at it
url="$(gh repo view "$NAME" --json url -q .url 2>/dev/null)"
if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "$(gh repo view "$NAME" --json sshUrl -q .sshUrl 2>/dev/null)" 2>/dev/null || true
fi

# 3. Ensure main + dev branches and push both
git branch -M main
git push -u origin main >/dev/null 2>&1 || echo "gh: main push skipped/failed (continuing)"
if ! git show-ref --verify --quiet refs/heads/dev; then git branch dev; fi
git push -u origin dev >/dev/null 2>&1 || echo "gh: dev push skipped/failed (continuing)"

echo "$url"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS. During implementation, confirm `gh repo create` flags (`--source`, `--push`) against `gh repo create --help`.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/create-github-repo.sh` (clean), then:
```bash
git add scripts/create-github-repo.sh tests/create_github_repo_test.sh
git commit -m "feat: create-github-repo.sh (repo + main/dev branches + push)"
```

---

### Task 9: `set-github-secrets.sh`

**Files:**
- Create: `scripts/set-github-secrets.sh`
- Test: `tests/set_github_secrets_test.sh`

**Interfaces:**
- Consumes: `gh`; a keys file (`PROD_KEY=`, `STAGING_KEY=` — from Task 7).
- Produces: `scripts/set-github-secrets.sh <repo> <keys-file>` — sets repo secrets `CONVEX_DEPLOY_KEY_PROD` / `CONVEX_DEPLOY_KEY_STAGING` from the keys file via stdin (never on argv/stdout), and ensures GitHub Environments `staging` and `production` exist. Does **not** delete the keys file — the deploy-host step (Task 10/11) still needs the values; the orchestration (Task 13) deletes it at the very end of Phase 2.

- [ ] **Step 1: Write the failing test**

`tests/set_github_secrets_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

log="$(mktemp)"
make_stub gh "echo \"gh \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'PROD_KEY=pk123\nSTAGING_KEY=sk456\n' > "$keys"

out="$(bash "$ROOT/scripts/set-github-secrets.sh" me/acme "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$(cat "$log")" "secret set CONVEX_DEPLOY_KEY_PROD" "sets prod secret"
assert_contains "$(cat "$log")" "secret set CONVEX_DEPLOY_KEY_STAGING" "sets staging secret"
# key values must not appear in gh argv log (they go via stdin)
case "$(cat "$log")" in *pk123*|*sk456*) echo "  FAIL: key value on argv"; FAILS=$((FAILS+1));; *) echo "  ok: keys not on argv";; esac
assert_eq "$([ -f "$keys" ]; echo $?)" "0" "keys file preserved for the deploy-host step"
rm -f "$log" "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write implementation**

`scripts/set-github-secrets.sh`:
```bash
#!/usr/bin/env bash
set -u
REPO="${1:?usage: set-github-secrets.sh <owner/repo> <keys-file>}"
KEYS_FILE="${2:?keys file required}"
# shellcheck disable=SC1090
. "$KEYS_FILE"   # defines PROD_KEY, STAGING_KEY

set_secret() { # <name> <value> — value via stdin, never argv
  printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null 2>&1 \
    && echo "gh: set secret $1" || { echo "gh: failed to set $1" >&2; return 1; }
}
set_secret CONVEX_DEPLOY_KEY_PROD "${PROD_KEY:-}" || exit 1
set_secret CONVEX_DEPLOY_KEY_STAGING "${STAGING_KEY:-}" || exit 1

for envname in staging production; do
  gh api -X PUT "repos/$REPO/environments/$envname" >/dev/null 2>&1 \
    && echo "gh: ensured environment $envname" || echo "gh: environment $envname not created (continuing)"
done

# NOTE: do not delete the keys file here — the deploy-host step still needs the
# values. The orchestration (Task 13) deletes it at the end of Phase 2.
echo "gh: secrets and environments configured"
```
Note: `gh secret set NAME` reads the value from stdin when no value arg is given — verify with `gh secret set --help` during implementation.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/set-github-secrets.sh` (clean; keep the `SC1090` disable), then:
```bash
git add scripts/set-github-secrets.sh tests/set_github_secrets_test.sh
git commit -m "feat: set-github-secrets.sh (Convex deploy keys + environments)"
```

---

### Task 10: `wire-vercel.sh`

**Files:**
- Create: `scripts/wire-vercel.sh`
- Test: `tests/wire_vercel_test.sh`

**Interfaces:**
- Consumes: `vercel` CLI (`VERCEL_TOKEN` in env); a keys file (`PROD_KEY=`, `STAGING_KEY=`) and the two Convex URLs.
- Produces: `scripts/wire-vercel.sh <project> <keys-file> --prod-url <u> --staging-url <u>` — links/creates the Vercel project, sets `CONVEX_DEPLOY_KEY` + `NEXT_PUBLIC_CONVEX_URL` per target (production ← prod values; preview+development ← staging values). Values piped via stdin. Prints the project URL and, if git-connect needs OAuth, the single remaining manual step.

- [ ] **Step 1: Write the failing test**

`tests/wire_vercel_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'PROD_KEY=pk\nSTAGING_KEY=sk\n' > "$keys"

out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" --prod-url https://p.convex.cloud --staging-url https://s.convex.cloud)"; rc=$?
assert_eq "$rc" "0" "succeeds"
l="$(cat "$log")"
assert_contains "$l" "env add CONVEX_DEPLOY_KEY production" "sets prod deploy key"
assert_contains "$l" "env add CONVEX_DEPLOY_KEY preview" "sets preview deploy key"
assert_contains "$l" "env add NEXT_PUBLIC_CONVEX_URL production" "sets prod url"
rm -f "$log" "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — script not found.

- [ ] **Step 3: Write implementation**

`scripts/wire-vercel.sh`:
```bash
#!/usr/bin/env bash
set -u
PROJECT="${1:?usage: wire-vercel.sh <project> <keys-file> --prod-url U --staging-url U}"; shift
KEYS_FILE="${1:?keys file required}"; shift
PROD_URL=""; STAGING_URL=""
while [ $# -gt 0 ]; do case "$1" in
  --prod-url) PROD_URL="$2"; shift 2;;
  --staging-url) STAGING_URL="$2"; shift 2;;
  *) shift;; esac; done
# shellcheck disable=SC1090
. "$KEYS_FILE"

tok=(--token "${VERCEL_TOKEN:-}" --yes)

# Link/create project (idempotent)
vercel link "${tok[@]}" --project "$PROJECT" >/dev/null 2>&1 || echo "vercel: link/create returned non-zero (continuing)"

add_env() { # <name> <target> <value>
  printf '%s' "$3" | vercel env add "$1" "$2" "${tok[@]}" >/dev/null 2>&1 \
    && echo "vercel: set $1 [$2]" || echo "vercel: $1 [$2] may already exist (continuing)"
}
add_env CONVEX_DEPLOY_KEY production  "${PROD_KEY:-}"
add_env CONVEX_DEPLOY_KEY preview     "${STAGING_KEY:-}"
add_env CONVEX_DEPLOY_KEY development  "${STAGING_KEY:-}"
add_env NEXT_PUBLIC_CONVEX_URL production  "$PROD_URL"
add_env NEXT_PUBLIC_CONVEX_URL preview     "$STAGING_URL"
add_env NEXT_PUBLIC_CONVEX_URL development  "$STAGING_URL"

echo "vercel: env configured for $PROJECT"
echo "NOTE: if the GitHub repo isn't linked to Vercel yet, connect it once in the Vercel dashboard (Project → Settings → Git)."
```
Note: verify `vercel env add <name> <target>` reads the value from stdin, and the correct `vercel link`/`vercel project add` invocation, against `vercel --help` during implementation. Set the build command (`npx convex deploy --cmd 'npm run build'`) either here via `vercel` project settings or documented as the one dashboard field to set — decide during implementation based on CLI support.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/wire-vercel.sh` (clean; keep `SC1090` disable), then:
```bash
git add scripts/wire-vercel.sh tests/wire_vercel_test.sh
git commit -m "feat: wire-vercel.sh (project link + per-target env vars)"
```

---

### Task 11: `wire-netlify.sh`

**Files:**
- Create: `scripts/wire-netlify.sh`
- Test: `tests/wire_netlify_test.sh`

**Interfaces:**
- Consumes: `netlify` CLI; keys file + two Convex URLs.
- Produces: `scripts/wire-netlify.sh <site> <keys-file> --prod-url U --staging-url U` — creates the site (idempotent) and sets `CONVEX_DEPLOY_KEY` + `NEXT_PUBLIC_CONVEX_URL` per context (`production` ← prod; `deploy-preview` + `branch-deploy` ← staging).

- [ ] **Step 1: Write the failing test**

`tests/wire_netlify_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"
log="$(mktemp)"
make_stub netlify "echo \"netlify \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'PROD_KEY=pk\nSTAGING_KEY=sk\n' > "$keys"
out="$(bash "$ROOT/scripts/wire-netlify.sh" acme "$keys" --prod-url https://p --staging-url https://s)"; rc=$?
assert_eq "$rc" "0" "succeeds"
l="$(cat "$log")"
assert_contains "$l" "env:set CONVEX_DEPLOY_KEY" "sets deploy key"
assert_contains "$l" "production" "targets production context"
assert_contains "$l" "deploy-preview" "targets deploy-preview context"
rm -f "$log" "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL.

- [ ] **Step 3: Write implementation**

`scripts/wire-netlify.sh`:
```bash
#!/usr/bin/env bash
set -u
SITE="${1:?usage: wire-netlify.sh <site> <keys-file> --prod-url U --staging-url U}"; shift
KEYS_FILE="${1:?keys file required}"; shift
PROD_URL=""; STAGING_URL=""
while [ $# -gt 0 ]; do case "$1" in
  --prod-url) PROD_URL="$2"; shift 2;;
  --staging-url) STAGING_URL="$2"; shift 2;;
  *) shift;; esac; done
# shellcheck disable=SC1090
. "$KEYS_FILE"

netlify sites:create --name "$SITE" >/dev/null 2>&1 || echo "netlify: site exists (continuing)"

set_ctx() { # <name> <context> <value>
  netlify env:set "$1" "$3" --context "$2" >/dev/null 2>&1 \
    && echo "netlify: set $1 [$2]" || echo "netlify: $1 [$2] failed (continuing)"
}
set_ctx CONVEX_DEPLOY_KEY production     "${PROD_KEY:-}"
set_ctx CONVEX_DEPLOY_KEY deploy-preview "${STAGING_KEY:-}"
set_ctx CONVEX_DEPLOY_KEY branch-deploy  "${STAGING_KEY:-}"
set_ctx NEXT_PUBLIC_CONVEX_URL production     "$PROD_URL"
set_ctx NEXT_PUBLIC_CONVEX_URL deploy-preview "$STAGING_URL"
set_ctx NEXT_PUBLIC_CONVEX_URL branch-deploy  "$STAGING_URL"
echo "netlify: env configured for $SITE"
```
Note: verify `netlify env:set --context` syntax against `netlify env:set --help` during implementation.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/wire-netlify.sh` (clean), then:
```bash
git add scripts/wire-netlify.sh tests/wire_netlify_test.sh
git commit -m "feat: wire-netlify.sh (site + per-context env vars)"
```

---

### Task 12: `sync.sh`

**Files:**
- Create: `scripts/sync.sh`
- Test: `tests/sync_test.sh`

**Interfaces:**
- Consumes: `command/init-2env.md`.
- Produces: `scripts/sync.sh` — copies `command/init-2env.md` to `${CLAUDE_HOME:-$HOME/.claude}/commands/init-2env.md`, creating the dir. Honors `CLAUDE_HOME` override for testability. Prints the destination path.

- [ ] **Step 1: Write the failing test**

`tests/sync_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
mkdir -p "$ROOT/command"; printf '# init-2env\n' > "$ROOT/command/init-2env.md"
home="$(mktemp -d)"
out="$(CLAUDE_HOME="$home/.claude" bash "$ROOT/scripts/sync.sh")"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$out" "$home/.claude/commands/init-2env.md" "prints destination"
assert_eq "$(cat "$home/.claude/commands/init-2env.md")" "# init-2env" "copies content"
rm -rf "$home"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — script not found (and/or `command/init-2env.md` missing → created in this step's test; Task 13 fills real content).

- [ ] **Step 3: Write implementation**

`scripts/sync.sh`:
```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/command/init-2env.md"
[ -f "$SRC" ] || { echo "sync: $SRC not found" >&2; exit 1; }
DEST_DIR="${CLAUDE_HOME:-$HOME/.claude}/commands"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/init-2env.md"
echo "$DEST_DIR/init-2env.md"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Lint & commit**

Run: `shellcheck scripts/sync.sh` (clean), then:
```bash
git add scripts/sync.sh tests/sync_test.sh command/init-2env.md
git commit -m "feat: sync.sh copies command into ~/.claude/commands"
```

---

### Task 13: The `/init-2env` command (orchestration)

**Files:**
- Create/replace: `command/init-2env.md`
- Test: `tests/command_lint_test.sh`

**Interfaces:**
- Consumes: all `scripts/*.sh`, all `templates/*`, Linear MCP tools.
- Produces: the command markdown Claude executes. No runtime unit test (it drives external services); a structural lint asserts valid frontmatter, that it references each script and template, and that it contains no stray `{{VAR}}` (the command itself is not stamped).

- [ ] **Step 1: Write the failing structural-lint test**

`tests/command_lint_test.sh`:
```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
f="$ROOT/command/init-2env.md"
c="$(cat "$f")"
assert_contains "$c" "description:" "has frontmatter description"
assert_contains "$c" "allowed-tools:" "declares allowed-tools"
for s in preflight setup-convex create-github-repo set-github-secrets wire-vercel wire-netlify; do
  assert_contains "$c" "$s" "references $s script"
done
assert_contains "$c" "Execute all" "has the single confirmation gate"
assert_contains "$c" "list_teams" "creates/looks up Linear team"
case "$c" in *"{{"*) echo "  FAIL: command contains unstamped {{ markers"; FAILS=$((FAILS+1));; *) echo "  ok: no stray markers";; esac
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — command has only the stub content from Task 12.

- [ ] **Step 3: Write the command**

Replace `command/init-2env.md` with the full orchestration. Structure (write it out completely; this is the spec's §4 flow made executable):

````markdown
---
description: Bootstrap a brand-new Next.js+Convex project with two environments (main=prod, dev=staging), GitHub CI, Vercel/Netlify, and a Linear team. Usage: /init-2env
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__list_teams, mcp__plugin_linear_linear__list_projects, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Bootstrap a two-environment (main=production, dev=staging) Next.js + Convex project **from scratch** in the current empty directory. This repo's `scripts/` and `templates/` (path: the init-2env source repo — resolve it from where this command was synced, or ask) do the mechanical work.

Work top to bottom. There is exactly ONE confirmation gate (end of Phase 1). Preflight may stop earlier. On any Phase 2 failure, STOP, report what was created, and offer cleanup — never continue silently.

## Phase 0 — Preflight
- Run `scripts/preflight.sh --deploy <chosen>` (default vercel). If it exits non-zero, print the MISSING lines verbatim and STOP — tell the user exactly what to log in / export. Do not attempt logins yourself.

## Phase 1 — Interview + plan
Ask only what can't be inferred (use `AskUserQuestion`):
1. Project name → derive slug (kebab), repo name, Convex slug, Vercel/Netlify name, suggested Linear key (uppercase initials, e.g. "Maputo" → MAP).
2. GitHub repo private or public.
3. Deploy target: Vercel (default) or Netlify.
4. Confirm Linear team key and AUTHOR_PREFIX (initials from `git config user.name`).
Detect build/lint commands from the scaffold's `package.json` (default `npm run build` / `npm run lint`).

Print the FULL PLAN: repo (name+visibility), Convex project + `staging` deployment, GitHub secrets + environments, Linear team+project, deploy host + the exact env vars per target. Then ONE `AskUserQuestion`: **Execute all** / Edit / Cancel. Proceed only on "Execute all".

## Phase 2 — Autonomous execution (no further prompts)
1. **Scaffold**: run the official Next.js+Convex starter into the current dir (e.g. `npm create convex@latest -- -t nextjs` or the current recommended command — verify the flag with the starter's docs), then `git init` if needed and an initial commit.
2. **Convex**: `keys=$(mktemp)`; `scripts/setup-convex.sh <slug> --keys-file "$keys"`.
3. **GitHub**: `scripts/create-github-repo.sh <name> <vis>` → capture repo URL and `owner/repo`.
4. **Stamp templates** (export TEAM_KEY, TEAM_NAME, AUTHOR_PREFIX, PROJECT_NAME, BUILD_CMD, LINT_CMD, CONVEX_PROJECT_SLUG, then use `stamp_dir`/`stamp_file` from `scripts/lib/stamp.sh`):
   - `templates/github-workflows/*` → `.github/workflows/`
   - `templates/claude-commands/*` → `.claude/commands/`
   - `templates/CLAUDE.md` → `./CLAUDE.md`; `templates/docs/*` → `./docs/`; `templates/env/.env.example` → `./.env.example`
   - Commit the stamped files.
5. **Secrets**: `scripts/set-github-secrets.sh owner/repo "$keys"` (sets the two GitHub secrets + environments; does NOT delete the keys file). Resolve the two Convex deployment URLs (`prod`, `staging`) via `npx convex` (dashboard/CLI) and keep them for step 7.
6. **Linear**: `mcp__plugin_linear_linear__list_teams`; create the new team (via MCP if available, else GraphQL with LINEAR_API_KEY) with the confirmed key; create a project named after the app; note it. If team creation fails (plan limit), STOP and offer "project inside an existing team" (list via `list_projects`).
7. **Deploy host**: `scripts/wire-vercel.sh <name> "$keys" --prod-url <U> --staging-url <U>` (or `wire-netlify.sh`).
8. **Cleanup**: `rm -f "$keys"` — delete the keys file now that both the GitHub secrets and the deploy-host env vars are set. This is the single point where the file is removed.

## Phase 3 — Summary
Print: repo URL, Convex production+staging dashboard URLs, Vercel/Netlify URL, Linear team+project URLs, and any single manual step left (e.g. connect the repo in the Vercel dashboard if OAuth was needed). Confirm nothing was pushed/charged beyond the approved plan.

## Hard rules
- One confirmation gate only; Preflight is the sole earlier stop. Never log in on the user's behalf. Never print or write secret values. On failure, stop + report + offer cleanup; never leave half-created resources silently.
````
The keys-file lifecycle is fixed: Task 7 writes it, Task 9 reads (does not delete) it, Task 10/11 read it, and Phase 2 step 8 deletes it — the single removal point.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add command/init-2env.md tests/command_lint_test.sh
git commit -m "feat: /init-2env orchestration command"
```

---

### Task 14: README, sync, and end-to-end checklist

**Files:**
- Modify: `README.md`
- Create: `docs/E2E-CHECKLIST.md`

**Interfaces:**
- Consumes: everything.
- Produces: user-facing docs; the one-time prerequisites list; the manual E2E validation checklist.

- [ ] **Step 1: Write the full README**

`README.md` — cover: what `/init-2env` does; the one-time prerequisites (gh authed, convex login/`CONVEX_DEPLOY_KEY`, `VERCEL_TOKEN`/netlify login, `LINEAR_API_KEY` or Linear MCP); how to install (`bash scripts/sync.sh` → then `/init-2env` from any empty folder); repo layout; how to run tests (`bash tests/run.sh`) and lint (`shellcheck scripts/**/*.sh`); link to the spec and this plan.

- [ ] **Step 2: Write the E2E checklist**

`docs/E2E-CHECKLIST.md` — a manual, gated end-to-end run into throwaway resources: run `/init-2env` in an empty dir; verify (a) repo has `main`+`dev` and both workflows, (b) Convex project has `production`+`staging`, (c) pushing to `dev` deploys staging, (d) Vercel/Netlify env vars present per target, (e) Linear team+project exist and `/issue`+`/close-issue` resolve statuses. Note it creates billable resources — run in a sandbox account.

- [ ] **Step 3: Sync the command locally**

Run: `bash scripts/sync.sh`
Expected: prints `~/.claude/commands/init-2env.md`; the command is now invocable as `/init-2env`.

- [ ] **Step 4: Full suite + lint green**

Run: `bash tests/run.sh && shellcheck scripts/*.sh scripts/lib/*.sh`
Expected: `ALL TESTS PASSED` and no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/E2E-CHECKLIST.md
git commit -m "docs: README, prerequisites, and E2E validation checklist"
```

---

## Self-Review

**Spec coverage:**
- §3 repo layout → Tasks 1–14 create every path (command, templates/*, scripts/*, sync, docs). ✓
- §4 command flow (preflight, interview+gate, autonomous Phase 2, summary, error philosophy) → Task 13. ✓
- §5 Convex two-env + CI → Tasks 4 (workflows), 7 (setup-convex). ✓
- §6 Vercel/Netlify env vars → Tasks 10, 11. ✓
- §7 Linear + issue/close-issue templates → Tasks 5 (templates), 13 (Linear creation). ✓
- §8 components/boundaries → one file per responsibility across tasks. ✓
- §9 testing (stamp unit, preflight, script fail-clean via stubs, template render, shellcheck) → Tasks 2,3,4,5,6,7,8,9,10,11,12 tests + Task 14 lint. ✓
- §11 prerequisites → Task 3 (preflight) + Task 14 (README). ✓
- Secrets-never-printed constraint → asserted in Tasks 7, 9, 10. ✓

**Placeholder scan:** The two "verify the exact CLI flag during implementation" notes (Convex deploy confirm flag, gh/vercel/netlify flags, starter command) are deliberate verification steps against live `--help`, not content placeholders — every step still ships concrete commands. No `TODO`/`TBD` in deliverables.

**Type consistency:** keys-file contract `PROD_KEY=` / `STAGING_KEY=` is written by Task 7 and read identically by Tasks 9, 10, 11. Env var names `CONVEX_DEPLOY_KEY_PROD`/`_STAGING` consistent across Tasks 4, 7, 9. Marker names (`TEAM_KEY`, `AUTHOR_PREFIX`, `TEAM_NAME`, `BUILD_CMD`, `LINT_CMD`, `PROJECT_NAME`, `CONVEX_PROJECT_SLUG`) consistent across Tasks 5, 6, 13. `stamp_file`/`stamp_dir` signatures consistent from Task 2 onward. ✓

**Keys-file lifecycle (resolved):** Task 7 writes the keys file; Task 9 reads it without deleting; Tasks 10/11 read it; Phase 2 step 8 (Task 13) deletes it — a single, unambiguous removal point. The Task 9 test asserts the file is preserved.
