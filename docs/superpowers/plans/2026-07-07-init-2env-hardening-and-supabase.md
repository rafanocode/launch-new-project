# init-2env hardening + Supabase backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 7 correctness bugs in the existing Convex-only `/init-2env` implementation, and add Supabase as a second selectable backend (two sub-modes: separate projects + SQL migrations, or a single project + persistent branch).

**Architecture:** Bug fixes land first, in the existing files, with no shape change. Supabase support is additive: a new `scripts/setup-supabase.sh` parallel to `scripts/setup-convex.sh`, new CI templates, and small `--backend`-aware branches added to the existing `wire-vercel.sh` / `wire-netlify.sh` / `set-github-secrets.sh` / `preflight.sh`. `command/init-2env.md` gains the interview questions and branches Phase 2 on `backend`.

**Tech Stack:** Bash (`set -u`, portable — no bash4-only features, no associative arrays, macOS ships bash 3.2), `jq` (new dependency, added this plan), `shellcheck`, the project's own `tests/run.sh` harness (stub CLIs via `tests/lib/with_stubs.sh`, assertions via `tests/lib/assert.sh`).

## Global Constraints

- Every script keeps the existing contract: exits **0** only on real success or a genuinely idempotent no-op ("already exists" for operations that are truly re-runnable); exits **non-zero** on any other failure, with the error printed to stderr. No more `|| echo "...(continuing)"` swallowing real failures — that pattern is exactly what this plan removes from `wire-vercel.sh`/`wire-netlify.sh`.
- Secrets (keys, tokens, passwords) are **never** printed to stdout and **never** passed as a CLI positional/flag argument when a stdin or env-var alternative exists (existing rule; verified during this plan that `vercel env add` reads value from stdin and `VERCEL_TOKEN` env var is the correct auth mechanism — not `--token` on argv, which leaks in `ps`).
- The `--keys-file` contract is unchanged: written once (`umask 077`), read by later steps, deleted exactly once by the orchestration at the end of Phase 2.
- Every new/changed script must pass `shellcheck` with no output, and have a matching `tests/*_test.sh` that passes under `bash tests/run.sh`.
- No bash4+ syntax (no `declare -A`, no `mapfile`) — this repo's scripts must run under the bash 3.2 that ships with macOS.
- `jq` is added as a new one-time prerequisite (checked in `scripts/preflight.sh` unconditionally, documented in `README.md`), used by the Supabase provisioning script and by the improved Netlify site-idempotency check.

---

## Part A — Fixes

### Task 1: `scripts/preflight.sh` — real session checks, not just binary presence

Fixes analysis items #2 and #3: `command -v convex` false-negatives when only `npx convex` is available; Vercel/Netlify checks never verify an actual session, so a missing/invalid token silently reports "OK" (compounded by Task 2/3's current silent-continue bug in the wiring scripts).

**Files:**
- Modify: `scripts/preflight.sh` (full rewrite, file is 24 lines)
- Test: `tests/preflight_test.sh` (extend)

**Interfaces:**
- Consumes: none (this is the entry point script).
- Produces: `scripts/preflight.sh --deploy vercel|netlify [--backend convex|supabase]` — exit 0 iff everything required is present; on exit non-zero, prints one `MISSING <name>: <hint>` line per missing prerequisite (existing contract, extended with a `jq` check and, when `--backend supabase`, a `supabase` CLI + session check). The `--backend` flag defaults to `convex` when omitted, so existing callers/tests keep working unchanged.

- [ ] **Step 1: Write the failing tests for the new checks**

Replace `tests/preflight_test.sh` with:

```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

# All good: gh authed, convex present (global binary), vercel authed, jq present
make_stub gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'
make_stub convex 'exit 0'
make_stub vercel 'case "$1" in whoami) exit 0;; *) exit 0;; esac'
make_stub jq 'exit 0'

out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel)"; rc=$?
assert_eq "$rc" "0" "exit 0 when all present"
assert_contains "$out" "OK gh" "reports gh ok"
assert_contains "$out" "OK convex" "reports convex ok"
assert_contains "$out" "OK vercel" "reports vercel ok"
assert_contains "$out" "OK jq" "reports jq ok"

# gh missing auth -> fatal
make_stub gh 'case "$1 $2" in "auth status") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when gh not authed"
assert_contains "$out" "MISSING gh" "reports gh missing with hint"
make_stub gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'

# convex: no global binary, but npx convex works -> still OK (fix #2)
make_stub convex '' # placeholder body, will be removed below
rm -f "$STUB_BIN/convex"
make_stub npx 'case "$*" in *"convex --version"*) exit 0;; *) exit 1;; esac'
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel)"; rc=$?
assert_eq "$rc" "0" "exit 0 when only npx convex is available (fix #2)"
assert_contains "$out" "OK convex" "reports convex ok via npx"
make_stub convex 'exit 0' # restore for subsequent cases

# vercel: binary present but not authed (no VERCEL_TOKEN, whoami fails) -> fatal (fix #3)
make_stub vercel 'case "$1" in whoami) exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x env -u VERCEL_TOKEN bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when vercel binary present but not authed"
assert_contains "$out" "MISSING vercel" "reports vercel not authed"
make_stub vercel 'case "$1" in whoami) exit 0;; *) exit 0;; esac'

# jq missing -> fatal
rm -f "$STUB_BIN/jq"
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when jq missing"
assert_contains "$out" "MISSING jq" "reports jq missing"
make_stub jq 'exit 0'

# CLIs present but LINEAR_API_KEY unset -> fatal (needed to create Linear team/project)
out="$(env -u LINEAR_API_KEY bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when LINEAR_API_KEY unset"
assert_contains "$out" "MISSING linear" "reports linear missing"

# --backend supabase: supabase CLI missing -> fatal
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when backend=supabase and supabase CLI missing"
assert_contains "$out" "MISSING supabase" "reports supabase cli missing"

# --backend supabase: supabase CLI present, SUPABASE_ACCESS_TOKEN unset, no session -> fatal
make_stub supabase 'case "$1 $2" in "projects list") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x env -u SUPABASE_ACCESS_TOKEN bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when backend=supabase and no supabase session"
assert_contains "$out" "MISSING supabase" "reports supabase not authed"

# --backend supabase: SUPABASE_ACCESS_TOKEN set -> OK without calling projects list
out="$(LINEAR_API_KEY=x SUPABASE_ACCESS_TOKEN=tok bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase)"; rc=$?
assert_eq "$rc" "0" "exit 0 when backend=supabase and SUPABASE_ACCESS_TOKEN set"
assert_contains "$out" "OK supabase" "reports supabase ok"

exit "$FAILS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/preflight_test.sh`
Expected: multiple FAILs — `jq`/`supabase` checks don't exist yet, `--backend` flag is unrecognized (silently ignored by the current `case ... *) shift;;` catch-all, so those assertions fail because the script never prints `OK jq`/`MISSING jq`/`OK supabase`).

- [ ] **Step 3: Rewrite `scripts/preflight.sh`**

```bash
#!/usr/bin/env bash
set -u
DEPLOY="vercel"
BACKEND="convex"
while [ $# -gt 0 ]; do case "$1" in
  --deploy) DEPLOY="$2"; shift 2;;
  --backend) BACKEND="$2"; shift 2;;
  *) shift;;
esac; done

fatal=0
check() { # <name> <hint> ; runs following command via "$@" after first two args
  local name="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "OK $name"; else echo "MISSING $name: $hint"; fatal=1; fi
}

check gh "run: gh auth login" gh auth status
check jq "run: brew install jq (or your package manager's jq)" command -v jq

convex_present() { command -v convex >/dev/null 2>&1 || npx --no-install convex --version >/dev/null 2>&1; }
check convex "run: npm i -g convex (or ensure npx convex works)" convex_present

if [ "$DEPLOY" = "netlify" ]; then
  netlify_authed() {
    command -v netlify >/dev/null 2>&1 || return 1
    [ -n "${NETLIFY_AUTH_TOKEN:-}" ] && return 0
    netlify status >/dev/null 2>&1
  }
  check netlify "set NETLIFY_AUTH_TOKEN or run: npm i -g netlify-cli && netlify login" netlify_authed
else
  vercel_authed() {
    command -v vercel >/dev/null 2>&1 || return 1
    if [ -n "${VERCEL_TOKEN:-}" ]; then
      vercel whoami --token "$VERCEL_TOKEN" >/dev/null 2>&1
    else
      vercel whoami >/dev/null 2>&1
    fi
  }
  check vercel "set VERCEL_TOKEN or run: vercel login" vercel_authed
fi

if [ "$BACKEND" = "supabase" ]; then
  supabase_authed() {
    command -v supabase >/dev/null 2>&1 || return 1
    [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] && return 0
    supabase projects list >/dev/null 2>&1
  }
  check supabase "set SUPABASE_ACCESS_TOKEN or run: npm i -g supabase && supabase login" supabase_authed
fi

# Linear is required: the command creates the team/project via the Linear GraphQL API.
if [ -n "${LINEAR_API_KEY:-}" ]; then echo "OK linear (LINEAR_API_KEY)"; else echo "MISSING linear: export LINEAR_API_KEY (needed to create the Linear team/project)"; fatal=1; fi

exit "$fatal"
```

Note on `vercel whoami --token`: kept here only for the *check* (a one-shot verification call); the plumbing scripts (`wire-vercel.sh`, Task 2) rely on the `VERCEL_TOKEN` env var alone, per the Vercel CLI's own CI guidance ("use `VERCEL_TOKEN` env var, not `--token` — it leaks in process listings"). A single `--token` use in a diagnostic check that never touches a keys file is a reasonable, low-risk exception; production plumbing must not repeat it.

- [ ] **Step 4: Run the test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/preflight_test.sh`
Expected: `FAILS` prints `0` (no `FAIL:` lines), script exits 0.

Also run: `shellcheck scripts/preflight.sh` — expected: no output.

- [ ] **Step 5: Run the full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/preflight.sh tests/preflight_test.sh
git commit -m "$(cat <<'EOF'
fix: preflight accepts npx convex and verifies real deploy-host sessions

command -v convex false-negatived for npx-only setups even though the
rest of the command already shells out via npx. Vercel/Netlify checks
only looked for the binary, not a working session/token, so preflight
could report OK and then fail invisibly later. Also adds a jq check
(new dependency, needed by upcoming Supabase support) and an optional
--backend supabase check.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `scripts/wire-vercel.sh` — real failure handling

Fixes analysis item #1 for the Vercel path. Every call currently ends in `|| echo "...(continuing)"`, so the script always exits 0 even when `vercel env add` fails because of bad auth. Verified via the Vercel CLI skill: `vercel env add --force` makes re-adding an existing var succeed instead of prompting/failing, so there is no longer a legitimate "already exists" case to swallow — any non-zero exit here is a real failure and must propagate. Also drops the `--token` flag (kept only in Task 1's diagnostic check) in favor of the `VERCEL_TOKEN` env var, per the CLI's own CI guidance, avoiding a token appearing in `ps`/process listings.

**Files:**
- Modify: `scripts/wire-vercel.sh` (full rewrite, file is 32 lines)
- Test: `tests/wire_vercel_test.sh` (extend with a real-failure case)

**Interfaces:**
- Consumes: keys file with `PROD_KEY`/`STAGING_KEY` (Convex, existing) written by `scripts/setup-convex.sh`.
- Produces: `wire-vercel.sh <project> <keys-file> [backend]` — `backend` is an optional 3rd positional, defaulting to `convex` (Task 9 adds the `supabase` branch; this task only touches the Convex path and the shared error-handling helpers). Exits non-zero on any real failure with the error on stderr; exits 0 only on success.

- [ ] **Step 1: Write the failing test (failure path)**

Append to `tests/wire_vercel_test.sh` (keep the existing happy-path assertions above; the file becomes):

```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'PROD_KEY=pk\nSTAGING_KEY=sk\n' > "$keys"

out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds"
l="$(cat "$log")"
assert_contains "$l" "env add CONVEX_DEPLOY_KEY production" "sets prod deploy key"
assert_contains "$l" "env add CONVEX_DEPLOY_KEY preview" "sets preview deploy key"
assert_contains "$l" "env add CONVEX_DEPLOY_KEY development" "sets development deploy key"
assert_contains "$l" "--force" "uses --force so re-runs don't fail on existing vars"
assert_not_contains "$l" "--token" "does not pass the token on argv (VERCEL_TOKEN env var only)"
assert_not_contains "$l" "NEXT_PUBLIC_CONVEX_URL" "does not store convex url (build-injected)"
rm -f "$log"

# Real failure (e.g. bad auth) must NOT be swallowed
make_stub vercel 'case "$1 $2" in "env add") exit 1;; "link") exit 1;; *) exit 0;; esac'
out="$(VERCEL_TOKEN=bad bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "real vercel failure exits non-zero, not silently continuing"

rm -f "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_vercel_test.sh`
Expected: FAIL on `--force`, `--token`, and the real-failure-exits-non-zero assertions (current script always exits 0 and still passes `--token`).

- [ ] **Step 3: Rewrite `scripts/wire-vercel.sh`**

```bash
#!/usr/bin/env bash
set -u
# Links/creates a Vercel project and sets the backend's env vars per target.
# Auth is via the VERCEL_TOKEN env var only (never passed as --token on argv,
# which would leak in `ps`/process listings — see the Vercel CLI's own CI
# guidance). Values are piped via stdin to `vercel env add`, never passed on
# argv or printed to stdout. `--force` makes re-adding an existing var
# succeed instead of prompting, so every remaining non-zero exit here is a
# real failure (auth, network, invalid project) and must propagate.
#
# Reads the backend's keys from the keys file (written earlier by
# setup-convex.sh / setup-supabase.sh). Does not delete the keys file;
# orchestration does that.
PROJECT="${1:?usage: wire-vercel.sh <project> <keys-file> [backend]}"; shift
KEYS_FILE="${1:?keys file required}"; shift
BACKEND="${1:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"

vercel link --project "$PROJECT" --yes >/dev/null 2>&1 \
  || { echo "vercel: link/create failed for $PROJECT" >&2; exit 1; }

add_env() { # <name> <target> <value>
  printf '%s' "$3" | vercel env add "$1" "$2" --force --yes >/dev/null 2>&1 \
    && echo "vercel: set $1 [$2]" \
    || { echo "vercel: failed to set $1 [$2]" >&2; return 1; }
}

case "$BACKEND" in
  convex)
    add_env CONVEX_DEPLOY_KEY production   "${PROD_KEY:-}"    || exit 1
    add_env CONVEX_DEPLOY_KEY preview      "${STAGING_KEY:-}" || exit 1
    add_env CONVEX_DEPLOY_KEY development  "${STAGING_KEY:-}" || exit 1
    ;;
  supabase)
    echo "vercel: unknown backend 'supabase' handling not yet implemented" >&2
    exit 1
    ;;
  *)
    echo "vercel: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac

echo "vercel: env configured for $PROJECT"
echo "NOTE: if the GitHub repo isn't linked to Vercel yet, connect it once in the Vercel dashboard (Project → Settings → Git)."
echo "NOTE: the Vercel Build Command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL (Project → Settings → Build & Development Settings). The orchestration writes this into vercel.json; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var. If you created the project by hand, set it manually."
```

(The `supabase)` branch is a deliberate placeholder that fails loudly — Task 9 replaces it with the real implementation. Leaving it silently falling through to the `convex)` case would write Convex-shaped env vars for a Supabase project, which is worse than failing clearly.)

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_vercel_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/wire-vercel.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/wire-vercel.sh tests/wire_vercel_test.sh
git commit -m "$(cat <<'EOF'
fix: wire-vercel.sh no longer swallows real failures

Every vercel call ended in `|| echo "...(continuing)"`, so the script
always exited 0 even on auth/network failure — the Convex deploy key
could silently fail to be set and the only sign would be a broken
production build later. `--force` on `env add` removes the one
legitimate "already exists" case, so any remaining non-zero exit is a
real failure and now propagates. Also stops passing --token on argv
(VERCEL_TOKEN env var only), avoiding a token leak via ps/process
listings.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `scripts/wire-netlify.sh` — real failure handling

Same fix as Task 2, for Netlify. Netlify's `env:set` has no "already exists" concept at all (it always overwrites), so removing the silent-continue there is unconditional. `sites:create` *can* legitimately collide with an existing site of the same name — verified via the Netlify CLI's own `sites:list --json`, used here for a real idempotency check instead of guessing from exit codes. Also switches auth to the `NETLIFY_AUTH_TOKEN` env var (verified in Netlify's own CI docs — analogous to Vercel's `VERCEL_TOKEN`), which the current script didn't support at all (relied purely on a prior interactive `netlify login`).

**Files:**
- Modify: `scripts/wire-netlify.sh` (full rewrite, file is 31 lines)
- Test: `tests/wire_netlify_test.sh` (extend)

**Interfaces:**
- Consumes: keys file with `PROD_KEY`/`STAGING_KEY` (Convex).
- Produces: `wire-netlify.sh <site> <keys-file> [backend]` — same `[backend]` convention as Task 2 (defaults to `convex`).

- [ ] **Step 1: Write the failing test**

Replace `tests/wire_netlify_test.sh` with:

```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"
log="$(mktemp)"
make_stub netlify "echo \"netlify \$*\" >> $log
case \"\$1\" in
  sites:list) echo '[]';;
  *) : ;;
esac
exit 0"
keys="$(mktemp)"; printf 'PROD_KEY=pk\nSTAGING_KEY=sk\n' > "$keys"
out="$(NETLIFY_AUTH_TOKEN=t bash "$ROOT/scripts/wire-netlify.sh" acme "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds"
l="$(cat "$log")"
assert_contains "$l" "sites:create --name acme" "creates the site when sites:list shows none matching"
assert_contains "$l" "env:set CONVEX_DEPLOY_KEY" "sets deploy key"
assert_contains "$l" "--force" "uses --force to skip overwrite prompts"
assert_contains "$l" "production" "targets production context"
assert_contains "$l" "deploy-preview" "targets deploy-preview context"
assert_contains "$l" "branch-deploy" "targets branch-deploy context"
assert_not_contains "$l" "NEXT_PUBLIC_CONVEX_URL" "does not store convex url (build-injected)"
rm -f "$log"

# Site already exists (by name, via sites:list) -> reused, sites:create NOT called
log="$(mktemp)"
make_stub netlify "echo \"netlify \$*\" >> $log
case \"\$1\" in
  sites:list) echo '[{\"name\":\"acme\",\"site_id\":\"abc123\"}]';;
  *) : ;;
esac
exit 0"
out="$(NETLIFY_AUTH_TOKEN=t bash "$ROOT/scripts/wire-netlify.sh" acme "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds when site already exists"
assert_not_contains "$(cat "$log")" "sites:create" "does not recreate an existing site"
rm -f "$log"

# Real failure (e.g. bad auth on env:set) must NOT be swallowed
make_stub netlify 'case "$1" in
  sites:list) echo "[]"; exit 0;;
  sites:create) exit 0;;
  env:set) exit 1;;
  *) exit 0;;
esac'
out="$(NETLIFY_AUTH_TOKEN=bad bash "$ROOT/scripts/wire-netlify.sh" acme "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "real netlify failure exits non-zero, not silently continuing"

rm -f "$keys"
exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_netlify_test.sh`
Expected: multiple FAILs (`sites:list`-based idempotency and `--force` don't exist yet; real failures currently still exit 0).

- [ ] **Step 3: Rewrite `scripts/wire-netlify.sh`**

```bash
#!/usr/bin/env bash
set -u
# Creates a Netlify site (idempotent via `sites:list`, not exit-code
# guessing) and sets the backend's env vars per Netlify deploy context.
# Auth is via NETLIFY_AUTH_TOKEN (verified in Netlify's own CI docs,
# analogous to Vercel's VERCEL_TOKEN) or a prior `netlify login` session.
# `env:set` always overwrites (there is no "already exists" case for it),
# so any non-zero exit from it is a real failure and propagates.
#
# Reads the backend's keys from the keys file (written earlier by
# setup-convex.sh / setup-supabase.sh). Does not delete the keys file;
# orchestration does that.
#
# KNOWN LIMITATION: unlike `vercel env add` / `gh secret set`, which read the
# secret value from stdin, the Netlify CLI's `env:set` takes the value as a
# positional argument. There is no stdin option, so the deploy key transits
# the process argv here (visible in `ps`/shell history) instead of being
# piped in. This is a Netlify CLI limitation, not a choice made here.
SITE="${1:?usage: wire-netlify.sh <site> <keys-file> [backend]}"; shift
KEYS_FILE="${1:?keys file required}"; shift
BACKEND="${1:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"

auth=()
[ -n "${NETLIFY_AUTH_TOKEN:-}" ] && auth=(--auth "$NETLIFY_AUTH_TOKEN")

existing="$(netlify sites:list "${auth[@]}" --json 2>/dev/null | jq -r --arg n "$SITE" '.[] | select(.name == $n) | .site_id' | head -n1)"
if [ -n "$existing" ]; then
  echo "netlify: site $SITE exists ($existing), reusing"
else
  netlify sites:create --name "$SITE" "${auth[@]}" >/dev/null 2>&1 \
    || { echo "netlify: failed to create site $SITE" >&2; exit 1; }
  echo "netlify: site $SITE created"
fi

set_ctx() { # <name> <context> <value>
  netlify env:set "$1" "$3" --context "$2" --force "${auth[@]}" >/dev/null 2>&1 \
    && echo "netlify: set $1 [$2]" \
    || { echo "netlify: failed to set $1 [$2]" >&2; return 1; }
}

case "$BACKEND" in
  convex)
    set_ctx CONVEX_DEPLOY_KEY production     "${PROD_KEY:-}"    || exit 1
    set_ctx CONVEX_DEPLOY_KEY deploy-preview "${STAGING_KEY:-}" || exit 1
    set_ctx CONVEX_DEPLOY_KEY branch-deploy  "${STAGING_KEY:-}" || exit 1
    ;;
  supabase)
    echo "netlify: unknown backend 'supabase' handling not yet implemented" >&2
    exit 1
    ;;
  *)
    echo "netlify: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac
echo "netlify: env configured for $SITE"
echo "NOTE: the netlify.toml [build] command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL. The orchestration writes this into netlify.toml; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var."
```

(Same deliberate loud-failure placeholder for `supabase)` as Task 2; Task 10 replaces it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_netlify_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/wire-netlify.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/wire-netlify.sh tests/wire_netlify_test.sh
git commit -m "$(cat <<'EOF'
fix: wire-netlify.sh no longer swallows real failures

env:set always overwrites (no "already exists" case), so its
`|| echo "...(continuing)"` was hiding every real failure, including
auth errors. sites:create genuinely can collide on name, so that path
now checks `sites:list --json` first instead of guessing from an exit
code. Also adds NETLIFY_AUTH_TOKEN support (Netlify's CI-recommended
auth env var, analogous to Vercel's VERCEL_TOKEN) — previously the
script only worked after an interactive `netlify login`.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `scripts/setup-convex.sh` — `--team` support

Fixes analysis item #4. Verified against the installed Convex CLI (`npx convex project create --help`): `--team <team_slug>` exists and "Defaults to your only team, or **prompts** when you belong to several." There is no `convex teams list` (or similar) subcommand to enumerate teams programmatically — confirmed via `npx convex --help` (no `teams` command in the top-level list). So, unlike Supabase (Task 6, which *can* self-resolve via `supabase orgs list`), this fix cannot auto-discover the team; it must require an explicit value when ambiguous, rather than risk an interactive prompt hanging in a non-interactive run.

**Files:**
- Modify: `scripts/setup-convex.sh` (full rewrite, file is 35 lines)
- Test: `tests/setup_convex_test.sh` (extend)

**Interfaces:**
- Consumes: none new.
- Produces: `setup-convex.sh <slug> --keys-file <path> [--team <team_slug>]`. `--team` also readable from the `CONVEX_TEAM` env var (flag wins if both given). If omitted and the account has more than one team, `convex project create` would prompt — since this script must never hang non-interactively, it now runs `project create` with stdin redirected from `/dev/null`, so an unexpected interactive prompt fails fast (non-zero exit) with a clear message instead of hanging, rather than silently blocking.

- [ ] **Step 1: Write the failing test**

Replace `tests/setup_convex_test.sh` with:

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

# --team is passed through to `project create`
log="$(mktemp)"
make_stub convex "echo \"convex \$*\" >> $log
case \"\$1 \$2\" in
  \"project create\") exit 0;;
  \"deployment create\") exit 0;;
  \"deployment token\") echo key; exit 0;;
  *) exit 0;;
esac"
keys="$(mktemp)"
bash "$ROOT/scripts/setup-convex.sh" acme --keys-file "$keys" --team my-team >/dev/null
assert_contains "$(cat "$log")" "--team my-team" "passes --team through to project create"
rm -f "$log" "$keys"

# CONVEX_TEAM env var also works (flag not given)
log="$(mktemp)"
make_stub convex "echo \"convex \$*\" >> $log; exit 0"
keys="$(mktemp)"
CONVEX_TEAM=env-team bash "$ROOT/scripts/setup-convex.sh" acme --keys-file "$keys" >/dev/null
assert_contains "$(cat "$log")" "--team env-team" "passes CONVEX_TEAM env var through to project create"
rm -f "$log" "$keys"

exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_convex_test.sh`
Expected: FAIL on both new `--team`/`CONVEX_TEAM` assertions (current script never passes `--team`).

- [ ] **Step 3: Rewrite `scripts/setup-convex.sh`**

```bash
#!/usr/bin/env bash
set -u
# Creates (or reuses) a Convex project, ensures a "staging" prod-type
# deployment exists alongside the project's default production deployment,
# and mints deploy keys for both. Keys are written only to --keys-file
# (umask 077), never to stdout — later setup steps (GitHub secrets, etc.)
# consume that file.
#
# --team / CONVEX_TEAM: `convex project create` defaults to the account's
# only team, or PROMPTS when there are several (verified via
# `npx convex project create --help`; there is no CLI subcommand to list
# teams, unlike Supabase's `orgs list`). Passing --team explicitly avoids
# that interactive prompt ever happening in a non-interactive run; stdin is
# also redirected from /dev/null so an unexpected prompt fails fast instead
# of hanging.
#
# Note: real end-to-end provisioning (e.g. that a freshly created project
# actually has a default "prod" deployment available for token minting) is
# validated by the E2E checklist, not by these unit tests — the tests here
# stub the `convex` CLI so no real Convex account is touched.
SLUG="${1:?usage: setup-convex.sh <slug> --keys-file <path> [--team <team_slug>]}"; shift
KEYS_FILE=""
TEAM="${CONVEX_TEAM:-}"
while [ $# -gt 0 ]; do case "$1" in
  --keys-file) KEYS_FILE="$2"; shift 2;;
  --team) TEAM="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$KEYS_FILE" ] || { echo "setup-convex: --keys-file required" >&2; exit 2; }

team_flag=()
[ -n "$TEAM" ] && team_flag=(--team "$TEAM")

# 1. Project (idempotent: a non-zero "already exists" is not fatal)
echo "convex: ensuring project $SLUG"
# "${team_flag[@]+"${team_flag[@]}"}" (not a bare "${team_flag[@]}") — expanding a
# declared-but-empty array under `set -u` is an unbound-variable error on bash
# <4.4 (confirmed on this repo's target, macOS's bash 3.2); the ${arr[@]+word}
# form only substitutes when the array actually has elements.
convex project create "$SLUG" "${team_flag[@]+"${team_flag[@]}"}" </dev/null >/dev/null 2>&1 \
  || echo "convex: project exists or already created, continuing"

# 2. Staging prod-type deployment (idempotent)
echo "convex: ensuring staging deployment"
convex deployment create staging --type prod </dev/null >/dev/null 2>&1 || echo "convex: staging exists, continuing"

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

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_convex_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/setup-convex.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/setup-convex.sh tests/setup_convex_test.sh
git commit -m "$(cat <<'EOF'
fix: setup-convex.sh supports --team / CONVEX_TEAM

`convex project create` prompts interactively when the account belongs
to more than one team, which would hang a non-interactive run. There is
no CLI subcommand to enumerate teams (verified via --help), so this
requires an explicit --team/CONVEX_TEAM rather than trying to
auto-resolve it; stdin is also redirected from /dev/null so any
unexpected prompt fails fast instead of hanging.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `templates/github-workflows/convex-deploy-dev.yml` — environment symmetry

Fixes analysis item #5: the prod workflow declares `environment: production`; the dev one doesn't declare `environment: staging`, even though `set-github-secrets.sh` already creates both GitHub Environments.

**Files:**
- Modify: `templates/github-workflows/convex-deploy-dev.yml`
- Test: `tests/templates_workflows_test.sh` (extend)

**Interfaces:**
- Consumes: none.
- Produces: no interface change — same stamped file, one added line.

- [ ] **Step 1: Write the failing test**

In `tests/templates_workflows_test.sh`, add after the existing `branches: [main]` assertion:

```bash
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "environment: staging" "dev workflow declares the staging GitHub Environment"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_workflows_test.sh`
Expected: FAIL — `environment: staging` not present yet.

- [ ] **Step 3: Edit the template**

In `templates/github-workflows/convex-deploy-dev.yml`, change:

```yaml
jobs:
  deploy:
    name: Deploy to staging deployment
    runs-on: ubuntu-latest
    env:
```

to:

```yaml
jobs:
  deploy:
    name: Deploy to staging deployment
    runs-on: ubuntu-latest
    environment: staging
    env:
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_workflows_test.sh`
Expected: `FAILS` is `0`.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add templates/github-workflows/convex-deploy-dev.yml tests/templates_workflows_test.sh
git commit -m "$(cat <<'EOF'
fix: convex-deploy-dev.yml declares the staging GitHub Environment

set-github-secrets.sh already creates both the staging and production
GitHub Environments, but only the prod workflow referenced its
environment. Symmetric now; no behavior change beyond making the
staging environment's protection rules (if any are added later) apply.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Part B — Supabase backend

### Task 6: `scripts/setup-supabase.sh` — mode `projects` (two projects + migrations)

New script, parallel to `setup-convex.sh`. Verified against the installed Supabase CLI (v2.98.2):
- `supabase orgs list -o json` returns `[{id, name, slug}]` — real shape confirmed against the user's own account.
- `supabase projects list -o json` returns `[{..., name, ref, organization_id, ...}]` — real shape confirmed the same way. Project **names are not unique** (no built-in idempotency), so this script does its own "list, match by name, reuse" instead of relying on `projects create` to fail cleanly.
- `supabase projects create <name> --org-id <id> --db-password <pw> -o json` — the DB password can only ever be captured **at creation time**; there is no CLI command to reset/reveal it later (confirmed: no `password` subcommand anywhere in `supabase --help`/`supabase projects --help`). So if a project with the target name already exists from a prior partial run, this script cannot safely resume it (the password is unrecoverable) — it stops with a clear message instead of guessing, consistent with `command/init-2env.md`'s existing "on failure, stop, report what was created, offer cleanup" philosophy (Task 14 wires that message into Phase 3).
- `supabase projects api-keys --project-ref <ref> -o json` returns `[{name, api_key}]` (confirmed via the CLI's own source, `apps/cli-go/internal/projects/apiKeys/api_keys.go` and its test file). New projects use `type: publishable`/`type: secret` keys (not the legacy `anon`/`service_role` names) — confirmed via the same source (`api_keys_test.go`'s `TestToEnv`). This script extracts the client-safe key by `type == "publishable"`, falling back to `name == "anon"` for older/legacy-key projects, and treats an empty/null result as a hard failure (never writes an empty env var silently) since the installed CLI has no `--reveal` flag to un-redact a key if the API ever returns one masked.
- The real DB host pattern is `db.<ref>.supabase.co` (confirmed from a real project's `projects list -o json` output). The connection string uses `postgres` as the DB user and a script-generated alphanumeric password (avoids percent-encoding entirely, since `db push --db-url` requires the URL pre-encoded).

**Files:**
- Create: `scripts/setup-supabase.sh`
- Test: Create `tests/setup_supabase_test.sh`

**Interfaces:**
- Consumes: none.
- Produces: `setup-supabase.sh <slug> --mode projects --keys-file <path> [--org-id <id>]`. On success, writes to the keys file: `SUPABASE_REF_PROD`, `SUPABASE_URL_PROD`, `SUPABASE_PUBLISHABLE_KEY_PROD`, `SUPABASE_DB_URL_PROD`, and the `_STAGING` equivalents. Exits non-zero on any real failure (including "project already exists, password unrecoverable"). `--org-id` also readable from `SUPABASE_ORG_ID`; if neither is given and the account has exactly one org, it's used silently; if more than one, the script lists them on stderr and exits non-zero.
- Task 7 adds the `--mode branch` alternative to this same file.

- [ ] **Step 1: Write the failing test**

Create `tests/setup_supabase_test.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

stub_supabase_happy() {
make_stub supabase '
echo "supabase $*" >> "${SUPABASE_CALL_LOG:-/dev/null}"
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme Org\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"refabc123\",\"name\":\"$3\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_xyz\"},{\"name\":\"default\",\"type\":\"secret\",\"api_key\":\"sb_secret_xyz\"}]"; exit 0;;
  *) exit 0;;
esac'
}

# Happy path: single org auto-resolved, two projects created, keys extracted
SUPABASE_CALL_LOG="$(mktemp)"; export SUPABASE_CALL_LOG
stub_supabase_happy
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds when org is unambiguous and projects are new"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=refabc123" "writes prod ref"
assert_contains "$k" "SUPABASE_URL_PROD=https://refabc123.supabase.co" "writes prod url"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_PROD=sb_publishable_xyz" "writes prod publishable key"
assert_contains "$k" "SUPABASE_DB_URL_PROD=postgresql://postgres:" "writes prod db url"
assert_contains "$k" "SUPABASE_REF_STAGING=refabc123" "writes staging ref"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_STAGING=sb_publishable_xyz" "writes staging publishable key"
case "$out" in *sb_secret_xyz*) echo "  FAIL: secret key leaked to stdout"; FAILS=$((FAILS+1));; *) echo "  ok: no secret key on stdout";; esac
# the generated DB password must never appear on stdout either
prod_pw="$(printf '%s' "$k" | sed -n 's#^SUPABASE_DB_URL_PROD=postgresql://postgres:\([^@]*\)@.*#\1#p')"
assert_not_contains "$out" "$prod_pw" "generated db password never appears on stdout"
# --region is REQUIRED by the real CLI whenever stdin isn't a tty (verified
# against the installed CLI's source) — assert it's actually on the argv,
# not just that the (stubbed) call returns success regardless of its flags
assert_contains "$(cat "$SUPABASE_CALL_LOG")" "--region" "passes --region to projects create"
rm -f "$keys" "$SUPABASE_CALL_LOG"
unset SUPABASE_CALL_LOG

# Multiple orgs, no --org-id given -> fatal, lists them
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"},{\"id\":\"org2\",\"name\":\"Other\",\"slug\":\"org2\"}]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when multiple orgs and no --org-id"
assert_contains "$out" "org1" "lists org1 as a candidate"
assert_contains "$out" "org2" "lists org2 as a candidate"
rm -f "$keys"

# Zero orgs, no --org-id given -> fatal, distinct message from the multi-org case
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when zero orgs and no --org-id"
assert_contains "$out" "no organizations found" "reports zero orgs distinctly from the multi-org case"
assert_not_contains "$out" "multiple organizations" "does not misreport zero orgs as multiple"
rm -f "$keys"

# --mode branch is not yet implemented in this task (Task 7 replaces this
# stopgap) -> loud, non-zero exit, not a silent no-op success
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys" --org-id org1 2>&1)"; rc=$?
assert_fail_exit "$rc" "mode=branch stopgap exits non-zero rather than silently succeeding"
rm -f "$keys"

# --org-id explicit skips org resolution entirely
stub_supabase_happy
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" --org-id org2)"; rc=$?
assert_eq "$rc" "0" "succeeds with explicit --org-id"
rm -f "$keys"

# Project already exists (by name) -> fatal, password unrecoverable, no silent reuse
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[{\"name\":\"acme-prod\",\"ref\":\"existingref\"}]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when the target project already exists (password unrecoverable)"
assert_contains "$out" "acme-prod" "names the conflicting project"
rm -f "$keys"

# projects create real failure -> fatal (not swallowed)
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "quota exceeded" >&2; exit 1;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when projects create genuinely fails"
rm -f "$keys"

exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_supabase_test.sh`
Expected: FAIL — `scripts/setup-supabase.sh` doesn't exist yet (`bash: .../setup-supabase.sh: No such file or directory`, every assertion fails).

- [ ] **Step 3: Create `scripts/setup-supabase.sh`**

```bash
#!/usr/bin/env bash
set -u
# Creates (or, for mode=branch, extends) a Supabase backend for the
# two-environment model. Two modes:
#   --mode projects  Two separate Supabase projects (<slug>-prod,
#                     <slug>-staging), each with its own DB password,
#                     migrated independently via CI (see
#                     templates/github-workflows/supabase-deploy-*.yml).
#   --mode branch     One project (<slug>, production) plus a best-effort
#                      persistent branch named "dev" for staging. See the
#                      --mode branch block (Task 7) for its non-fatal
#                      failure handling.
#
# Keys/URLs/connection strings are written only to --keys-file (umask 077),
# never to stdout — later steps (deploy-host wiring) consume that file.
#
# DB passwords are only ever knowable at project-creation time (the
# Supabase CLI has no password-reset/reveal command). If a project with the
# target name already exists, this script cannot safely resume it and
# stops rather than guessing — re-run from scratch after deleting the
# leftover project (see command/init-2env.md's cleanup-on-failure step).
SLUG="${1:?usage: setup-supabase.sh <slug> --mode projects|branch --keys-file <path> [--org-id <id>]}"; shift
MODE=""
ORG_ID="${SUPABASE_ORG_ID:-}"
KEYS_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --org-id) ORG_ID="$2"; shift 2;;
  --keys-file) KEYS_FILE="$2"; shift 2;;
  *) shift;;
esac; done
case "$MODE" in projects|branch) ;; *) echo "setup-supabase: --mode projects|branch required" >&2; exit 2;; esac
[ -n "$KEYS_FILE" ] || { echo "setup-supabase: --keys-file required" >&2; exit 2; }

# --- org resolution -----------------------------------------------------
if [ -z "$ORG_ID" ]; then
  orgs_json="$(supabase orgs list -o json 2>/dev/null)" || { echo "setup-supabase: failed to list organizations" >&2; exit 1; }
  count="$(printf '%s' "$orgs_json" | jq 'length')"
  case "$count" in
    1) ORG_ID="$(printf '%s' "$orgs_json" | jq -r '.[0].id')" ;;
    0)
      echo "setup-supabase: no organizations found on this account — create one first (https://supabase.com/dashboard/org/new or 'supabase orgs create'), then re-run." >&2
      exit 1
      ;;
    *)
      echo "setup-supabase: multiple organizations found, pass --org-id (or export SUPABASE_ORG_ID):" >&2
      printf '%s' "$orgs_json" | jq -r '.[] | "  \(.id)  \(.name)"' >&2
      exit 1
      ;;
  esac
fi

# --- helpers --------------------------------------------------------------
gen_db_password() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

find_project_ref() { # <name>
  supabase projects list -o json 2>/dev/null | jq -r --arg n "$1" '.[] | select(.name == $n) | .ref' | head -n1
}

# Creates a NEW project named <name>; fails loudly (does not reuse) if one
# already exists, since its DB password is unrecoverable. On success prints
# "<ref> <password>" (space-separated) to stdout.
#
# --region is REQUIRED by `supabase projects create` whenever stdin isn't a
# live terminal (confirmed against the installed CLI's source,
# apps/cli-go/cmd/projects.go: `PreRunE` calls
# `cmd.MarkFlagRequired("region")` whenever `!term.IsTerminal(...)`) — which
# is exactly how this script always runs. Defaults to "us-east-1" (the
# CLI's own documented example value), overridable via SUPABASE_REGION.
create_project() { # <name>
  local name="$1" existing ref pw out region
  region="${SUPABASE_REGION:-us-east-1}"
  existing="$(find_project_ref "$name")"
  if [ -n "$existing" ]; then
    echo "setup-supabase: project '$name' already exists ($existing) but its DB password can only be captured at creation time — cannot safely resume." >&2
    echo "setup-supabase: delete '$name' (or the whole partial run) in the Supabase dashboard and re-run setup-supabase.sh from scratch." >&2
    return 1
  fi
  pw="$(gen_db_password)"
  out="$(supabase projects create "$name" --org-id "$ORG_ID" --db-password "$pw" --region "$region" -o json 2>&1)" \
    || { echo "setup-supabase: failed to create project '$name': $out" >&2; return 1; }
  ref="$(printf '%s' "$out" | jq -r '.ref // .id // empty' 2>/dev/null)"
  [ -n "$ref" ] || { echo "setup-supabase: could not determine project ref for '$name' from: $out" >&2; return 1; }
  printf '%s %s' "$ref" "$pw"
}

# Extracts the client-safe key (publishable, falling back to legacy anon)
# for a project ref. Fails loudly on an empty/null result rather than
# writing a broken env var — the installed CLI has no --reveal flag to
# un-redact a masked key, so a null here means something is genuinely wrong.
extract_public_key() { # <ref>
  local keys_json key
  keys_json="$(supabase projects api-keys --project-ref "$1" -o json 2>/dev/null)" || return 1
  key="$(printf '%s' "$keys_json" | jq -r '
    ([.[] | select(.type == "publishable")] | .[0].api_key) //
    ([.[] | select(.name == "anon")] | .[0].api_key) //
    empty')"
  [ -n "$key" ] && [ "$key" != "null" ] || return 1
  printf '%s' "$key"
}

write_env_block() { # <suffix PROD|STAGING> <ref> <password>
  local suffix="$1" ref="$2" pw="$3" pub
  pub="$(extract_public_key "$ref")" || { echo "setup-supabase: failed to extract a usable publishable/anon key for $ref" >&2; return 1; }
  {
    echo "SUPABASE_REF_${suffix}=${ref}"
    echo "SUPABASE_URL_${suffix}=https://${ref}.supabase.co"
    echo "SUPABASE_PUBLISHABLE_KEY_${suffix}=${pub}"
    echo "SUPABASE_DB_URL_${suffix}=postgresql://postgres:${pw}@db.${ref}.supabase.co:5432/postgres"
  } >> "$KEYS_FILE"
}

umask 077
: > "$KEYS_FILE"

if [ "$MODE" = "projects" ]; then
  prod_out="$(create_project "${SLUG}-prod")" || exit 1
  prod_ref="${prod_out%% *}"; prod_pw="${prod_out#* }"
  write_env_block PROD "$prod_ref" "$prod_pw" || exit 1

  staging_out="$(create_project "${SLUG}-staging")" || exit 1
  staging_ref="${staging_out%% *}"; staging_pw="${staging_out#* }"
  write_env_block STAGING "$staging_ref" "$staging_pw" || exit 1

  echo "supabase: setup complete, mode=projects (keys written to keys file)"
fi

# mode=branch is implemented by Task 7, which REPLACES this stopgap with the
# real branch-creation logic. Left as a loud, non-zero-exit placeholder here
# (rather than silently falling through and exiting 0 having done nothing)
# so this task is independently correct: a "does nothing, exits 0" mode is a
# false success, not a genuinely idempotent no-op.
if [ "$MODE" = "branch" ]; then
  echo "setup-supabase: --mode branch is not yet implemented" >&2
  exit 2
fi
```

(`${var%% *}` / `${var#* }` are POSIX parameter expansion, portable to bash 3.2 — no arrays or `read`/heredoc tricks needed.)

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_supabase_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/setup-supabase.sh` — expected: no output. Fix any quoting warnings shellcheck raises on the parameter-expansion split (`prod_out%% *` etc.) by keeping them double-quoted as shown.

- [ ] **Step 5: Make the script executable, run full suite, commit**

Run: `chmod +x scripts/setup-supabase.sh && bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/setup-supabase.sh tests/setup_supabase_test.sh
git commit -m "$(cat <<'EOF'
feat: add setup-supabase.sh (mode=projects) for the Supabase backend

Creates two Supabase projects (<slug>-prod, <slug>-staging) and writes
their ref/URL/publishable-key/db-connection-string to the keys file,
mirroring setup-convex.sh's contract. Verified against the installed
Supabase CLI: project names aren't unique (no built-in idempotency, so
this does its own list-then-create), DB passwords are only knowable at
creation time (no reset/reveal command), and new projects use
publishable/secret-type keys rather than legacy anon/service_role.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `scripts/setup-supabase.sh` — mode `branch` (best-effort persistent branch)

Adds the second mode to the same script. Verified: `supabase branches create <name> --persistent --project-ref <ref>` is a real, current CLI flag (`supabase branches create --help`). Neither the CLI help nor the fetched docs page confirm whether it requires the GitHub integration to be connected in the dashboard first — per the approved design (§2.4 of the spec), this is handled as **best-effort**: attempt it, and on failure, don't treat it as fatal for the whole run — record that staging isn't provisioned and let Phase 3 (Task 14) print the manual follow-up.

**Files:**
- Modify: `scripts/setup-supabase.sh` (add the `branch` mode block)
- Test: `tests/setup_supabase_test.sh` (extend)

**Interfaces:**
- Consumes: `create_project`, `write_env_block`, `extract_public_key` from Task 6 (same file).
- Produces: when `--mode branch`, writes `SUPABASE_REF_PROD`/etc. (prod project) always; on branch success also writes the `_STAGING` block plus `SUPABASE_STAGING_PROVISIONED=yes`; on branch failure writes `SUPABASE_STAGING_PROVISIONED=no` instead (no `_STAGING` keys) and exits **0** (the run as a whole still succeeded — only staging provisioning is incomplete, which is by design non-fatal). Any caller reading the keys file (Task 9/10's deploy-host wiring, Task 14's orchestration) must check `SUPABASE_STAGING_PROVISIONED` before assuming `_STAGING` values exist.

- [ ] **Step 1: Write the failing test**

First, REMOVE Task 6's stopgap-era test case from `tests/setup_supabase_test.sh` — the one asserting `--mode branch` exits non-zero via `assert_fail_exit "$rc" "mode=branch stopgap exits non-zero rather than silently succeeding"`. That assertion tested the placeholder this task replaces; with the real branch logic in place, a correctly-stubbed `--mode branch` call now succeeds (exit 0), so the old assertion would fail for the right reason (the stopgap is gone) but for a confusing one if left in place. Delete that whole test block (the `make_stub supabase` + `out=...` + `assert_fail_exit` + `rm -f "$keys"` lines for it).

Then append the new tests below (before the final `exit "$FAILS"`):

```bash
# mode=branch, branch creation succeeds
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"prodref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_prod\"}]"; exit 0;;
  "branches create") echo "{\"ref\":\"branchref1\"}"; exit 0;;
  "branches get") echo "{\"ref\":\"branchref1\"}"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "mode=branch succeeds when branch creation works"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=prodref1" "writes prod ref"
assert_contains "$k" "SUPABASE_STAGING_PROVISIONED=yes" "marks staging as provisioned"
assert_contains "$k" "SUPABASE_REF_STAGING=branchref1" "writes staging ref from the branch"
rm -f "$keys"

# mode=branch, branch creation fails -> non-fatal, staging marked not-provisioned
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"prodref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_prod\"}]"; exit 0;;
  "branches create") echo "GitHub integration not connected" >&2; exit 1;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "mode=branch still exits 0 when branch creation fails (non-fatal, best-effort)"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=prodref1" "still writes prod ref"
assert_contains "$k" "SUPABASE_STAGING_PROVISIONED=no" "marks staging as not provisioned"
assert_not_contains "$k" "SUPABASE_REF_STAGING" "does not write a staging ref when the branch failed"
assert_contains "$out" "connect this repo in Supabase" "prints the manual follow-up instruction"
rm -f "$keys"

exit "$FAILS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_supabase_test.sh`
Expected: FAIL — `--mode branch` currently only hits Task 6's stopgap (`echo "...not yet implemented" >&2; exit 2`), not the real branch-creation behavior these new assertions check for.

- [ ] **Step 3: Replace the stopgap with the real `branch` mode block**

In `scripts/setup-supabase.sh`, REPLACE Task 6's stopgap —
```bash
if [ "$MODE" = "branch" ]; then
  echo "setup-supabase: --mode branch is not yet implemented" >&2
  exit 2
fi
```
— with:

```bash
if [ "$MODE" = "branch" ]; then
  prod_out="$(create_project "${SLUG}")" || exit 1
  prod_ref="${prod_out%% *}"; prod_pw="${prod_out#* }"
  write_env_block PROD "$prod_ref" "$prod_pw" || exit 1

  branch_out="$(supabase branches create dev --persistent --project-ref "$prod_ref" -o json 2>&1)"
  if [ $? -eq 0 ]; then
    branch_ref="$(printf '%s' "$branch_out" | jq -r '.ref // empty' 2>/dev/null)"
  else
    branch_ref=""
  fi

  if [ -n "$branch_ref" ]; then
    # A persistent branch is its own project-like entity: it has its own
    # ref and API keys, but shares the parent project's DB password.
    write_env_block STAGING "$branch_ref" "$prod_pw" || exit 1
    echo "SUPABASE_STAGING_PROVISIONED=yes" >> "$KEYS_FILE"
    echo "supabase: setup complete, mode=branch (staging is a persistent branch of $prod_ref)"
  else
    echo "SUPABASE_STAGING_PROVISIONED=no" >> "$KEYS_FILE"
    echo "supabase: prod project ready ($prod_ref); persistent branch creation did not succeed (best-effort): $branch_out" >&2
    echo "supabase: connect this repo in Supabase → Settings → Integrations → GitHub, then create a persistent 'dev' branch from the dashboard (or re-run: supabase branches create dev --persistent --project-ref $prod_ref)."
  fi
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/setup_supabase_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/setup-supabase.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/setup-supabase.sh tests/setup_supabase_test.sh
git commit -m "$(cat <<'EOF'
feat: add setup-supabase.sh mode=branch (best-effort persistent branch)

Attempts `supabase branches create dev --persistent`. The CLI supports
this call, but whether it requires the GitHub integration pre-connected
in the dashboard isn't confirmed by the docs either way, so failure is
treated as non-fatal: the run still succeeds with the prod project
ready, SUPABASE_STAGING_PROVISIONED=no is written to the keys file, and
a manual follow-up instruction is printed — matching this command's
existing pattern for the Vercel/Netlify OAuth-connect friction point.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Supabase CI templates

New GitHub Actions workflows, parallel to the Convex pair. Uses `supabase db push --db-url "$SUPABASE_DB_URL"` — confirmed via `supabase db push --help` that `--db-url` pushes directly to a connection string with no `link`/access-token step needed, mirroring the single-secret shape `CONVEX_DEPLOY_KEY_*` already uses.

**Files:**
- Create: `templates/github-workflows/supabase-deploy-dev.yml`
- Create: `templates/github-workflows/supabase-deploy-prod.yml`
- Test: `tests/templates_workflows_test.sh` (extend)

**Interfaces:**
- Consumes: GitHub secrets `SUPABASE_DB_URL_STAGING` / `SUPABASE_DB_URL_PROD` (Task 9 wires these).
- Produces: no interface others depend on beyond the stamped files existing at these paths.

- [ ] **Step 1: Write the failing test**

Append to `tests/templates_workflows_test.sh` (before `exit "$FAILS"`):

```bash
for f in supabase-deploy-dev.yml supabase-deploy-prod.yml; do
  stamp_file "$ROOT/templates/github-workflows/$f" "$tmp/$f"
  assert_eq "$?" "0" "$f stamps clean"
done
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "SUPABASE_DB_URL_STAGING" "dev workflow uses staging db url secret"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "SUPABASE_DB_URL_PROD" "prod workflow uses prod db url secret"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "branches: [dev]" "supabase dev workflow triggers on dev"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "branches: [main]" "supabase prod workflow triggers on main"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "environment: staging" "supabase dev workflow declares staging environment"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "environment: production" "supabase prod workflow declares production environment"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "db push" "dev workflow pushes migrations"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_workflows_test.sh`
Expected: FAIL — the two new template files don't exist yet.

- [ ] **Step 3: Create the templates**

`templates/github-workflows/supabase-deploy-dev.yml`:

```yaml
name: Supabase Migrate (staging)

on:
  push:
    branches: [dev]
    paths:
      - 'supabase/migrations/**'
      - '.github/workflows/supabase-deploy-dev.yml'
  workflow_dispatch:

concurrency:
  group: supabase-deploy-staging
  cancel-in-progress: false

jobs:
  migrate:
    name: Push migrations to staging
    runs-on: ubuntu-latest
    environment: staging
    env:
      SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL_STAGING }}
    steps:
      - uses: actions/checkout@v4
      - name: Verify db url present
        run: |
          if [ -z "$SUPABASE_DB_URL" ]; then
            echo "::error::Missing secret SUPABASE_DB_URL_STAGING"; exit 1
          fi
      - uses: supabase/setup-cli@v1
      - name: Push migrations (staging)
        run: supabase db push --db-url "$SUPABASE_DB_URL"
```

`templates/github-workflows/supabase-deploy-prod.yml`:

```yaml
name: Supabase Migrate (production)

on:
  push:
    branches: [main]
    paths:
      - 'supabase/migrations/**'
      - '.github/workflows/supabase-deploy-prod.yml'
  workflow_dispatch:

concurrency:
  group: supabase-deploy-production
  cancel-in-progress: false

jobs:
  migrate:
    name: Push migrations to production
    runs-on: ubuntu-latest
    environment: production
    env:
      SUPABASE_DB_URL: ${{ secrets.SUPABASE_DB_URL_PROD }}
    steps:
      - uses: actions/checkout@v4
      - name: Verify db url present
        run: |
          if [ -z "$SUPABASE_DB_URL" ]; then
            echo "::error::Missing secret SUPABASE_DB_URL_PROD"; exit 1
          fi
      - uses: supabase/setup-cli@v1
      - name: Push migrations (production)
        run: supabase db push --db-url "$SUPABASE_DB_URL"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_workflows_test.sh`
Expected: `FAILS` is `0`.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add templates/github-workflows/supabase-deploy-dev.yml templates/github-workflows/supabase-deploy-prod.yml tests/templates_workflows_test.sh
git commit -m "$(cat <<'EOF'
feat: add Supabase migration CI workflows

Mirrors the Convex deploy pair's shape (paths filter, concurrency
group, environment declaration). Uses `supabase db push --db-url`
directly with a per-environment connection-string secret — no
`supabase link` or access token needed in CI, matching the
single-secret pattern CONVEX_DEPLOY_KEY_* already uses.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `scripts/set-github-secrets.sh` — Supabase secrets

The orchestration also needs the GitHub secrets Task 8's workflows consume. Currently this script hardcodes the two Convex secret names.

**Files:**
- Modify: `scripts/set-github-secrets.sh` (full rewrite, file is 26 lines)
- Test: Create `tests/set_github_secrets_test.sh` extension (check existing file first — it already exists per the repo listing; extend it)

**Interfaces:**
- Consumes: keys file (Convex: `PROD_KEY`/`STAGING_KEY`; Supabase: `SUPABASE_DB_URL_PROD`/`SUPABASE_DB_URL_STAGING`, and possibly `SUPABASE_STAGING_PROVISIONED=no` when branch mode's staging didn't provision).
- Produces: `set-github-secrets.sh <owner/repo> <keys-file> [backend]`, `backend` optional 3rd positional defaulting to `convex`. For `supabase`, sets `SUPABASE_DB_URL_PROD` / `SUPABASE_DB_URL_STAGING` as GitHub secrets — skipping the staging secret (with a clear log line, not a failure) when the keys file says `SUPABASE_STAGING_PROVISIONED=no`.

- [ ] **Step 1: Read the existing test file first**

Read `tests/set_github_secrets_test.sh` to match its current stub conventions exactly before extending it (do not guess its shape — this repo's test files vary slightly in style; copy what's there).

- [ ] **Step 2: Write the failing test**

Append these cases to `tests/set_github_secrets_test.sh` (after its existing Convex-path assertions, using the same `make_stub gh` pattern already present in that file):

```bash
# Supabase backend: sets SUPABASE_DB_URL_* secrets instead of Convex ones
log="$(mktemp)"
make_stub gh "echo \"gh \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'SUPABASE_DB_URL_PROD=postgresql://x\nSUPABASE_DB_URL_STAGING=postgresql://y\n' > "$keys"
out="$(bash "$ROOT/scripts/set-github-secrets.sh" acme/repo "$keys" supabase)"; rc=$?
assert_eq "$rc" "0" "succeeds for supabase backend"
l="$(cat "$log")"
assert_contains "$l" "secret set SUPABASE_DB_URL_PROD" "sets prod db url secret"
assert_contains "$l" "secret set SUPABASE_DB_URL_STAGING" "sets staging db url secret"
rm -f "$log" "$keys"

# Supabase backend, staging not provisioned (branch mode best-effort failure):
# skips the staging secret without failing the whole step
log="$(mktemp)"
make_stub gh "echo \"gh \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'SUPABASE_DB_URL_PROD=postgresql://x\nSUPABASE_STAGING_PROVISIONED=no\n' > "$keys"
out="$(bash "$ROOT/scripts/set-github-secrets.sh" acme/repo "$keys" supabase)"; rc=$?
assert_eq "$rc" "0" "succeeds even when staging wasn't provisioned"
l="$(cat "$log")"
assert_contains "$l" "secret set SUPABASE_DB_URL_PROD" "still sets prod db url secret"
assert_not_contains "$l" "SUPABASE_DB_URL_STAGING" "does not attempt to set a staging secret that has no value"
assert_contains "$out" "staging not provisioned" "explains why the staging secret was skipped"
rm -f "$log" "$keys"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/set_github_secrets_test.sh`
Expected: FAIL — the script doesn't accept a 3rd `backend` argument or branch on it yet (Convex path still runs, `SUPABASE_DB_URL_PROD` never gets set).

- [ ] **Step 4: Rewrite `scripts/set-github-secrets.sh`**

```bash
#!/usr/bin/env bash
set -u
REPO="${1:?usage: set-github-secrets.sh <owner/repo> <keys-file> [backend]}"
KEYS_FILE="${2:?keys file required}"
BACKEND="${3:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"   # defines PROD_KEY/STAGING_KEY (convex) or SUPABASE_DB_URL_* (supabase)

set_secret() { # <name> <value> — value via stdin, never argv
  if printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null 2>&1; then
    echo "gh: set secret $1"
  else
    echo "gh: failed to set $1" >&2
    return 1
  fi
}

case "$BACKEND" in
  convex)
    set_secret CONVEX_DEPLOY_KEY_PROD "${PROD_KEY:-}" || exit 1
    set_secret CONVEX_DEPLOY_KEY_STAGING "${STAGING_KEY:-}" || exit 1
    ;;
  supabase)
    set_secret SUPABASE_DB_URL_PROD "${SUPABASE_DB_URL_PROD:-}" || exit 1
    if [ "${SUPABASE_STAGING_PROVISIONED:-yes}" = "no" ]; then
      echo "gh: staging not provisioned (best-effort branch creation didn't complete) — skipping SUPABASE_DB_URL_STAGING"
    else
      set_secret SUPABASE_DB_URL_STAGING "${SUPABASE_DB_URL_STAGING:-}" || exit 1
    fi
    ;;
  *)
    echo "gh: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac

for envname in staging production; do
  gh api -X PUT "repos/$REPO/environments/$envname" >/dev/null 2>&1 \
    && echo "gh: ensured environment $envname" || echo "gh: environment $envname not created (continuing)"
done

# NOTE: do not delete the keys file here — the deploy-host step still needs the
# values. The orchestration deletes it at the end of Phase 2.
echo "gh: secrets and environments configured"
```

- [ ] **Step 5: Run test to verify it passes, run full suite, commit**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/set_github_secrets_test.sh` — expected: `FAILS` is `0`.
Run: `shellcheck scripts/set-github-secrets.sh` — expected: no output.
Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/set-github-secrets.sh tests/set_github_secrets_test.sh
git commit -m "$(cat <<'EOF'
feat: set-github-secrets.sh supports the Supabase backend

Sets SUPABASE_DB_URL_PROD/_STAGING instead of the Convex deploy keys
when backend=supabase. When branch-mode staging provisioning was
best-effort and didn't complete (SUPABASE_STAGING_PROVISIONED=no), the
staging secret is skipped with a clear message rather than failing the
whole step on an empty value.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: `scripts/wire-vercel.sh` — Supabase env vars

Replaces the `supabase)` placeholder from Task 2. Verified against the **official** `create-next-app -e with-supabase` starter (`vercel/next.js` repo, `examples/with-supabase`): its `.env.example` and `lib/supabase/server.ts` only ever read `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` — no secret/service_role key is used by the default scaffold, so none is wired here.

**Files:**
- Modify: `scripts/wire-vercel.sh`
- Test: `tests/wire_vercel_test.sh` (extend)

**Interfaces:**
- Consumes: keys file with `SUPABASE_URL_PROD`/`SUPABASE_PUBLISHABLE_KEY_PROD`/`SUPABASE_URL_STAGING`/`SUPABASE_PUBLISHABLE_KEY_STAGING` (and `SUPABASE_STAGING_PROVISIONED`) from Tasks 6/7.
- Produces: same CLI contract as Task 2, `backend=supabase` now implemented instead of erroring.

- [ ] **Step 1: Write the failing test**

Append to `tests/wire_vercel_test.sh` (before `exit "$FAILS"`):

```bash
# Supabase backend
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
keys="$(mktemp)"; printf 'SUPABASE_URL_PROD=https://p.supabase.co\nSUPABASE_PUBLISHABLE_KEY_PROD=pub_prod\nSUPABASE_URL_STAGING=https://s.supabase.co\nSUPABASE_PUBLISHABLE_KEY_STAGING=pub_staging\nSUPABASE_STAGING_PROVISIONED=yes\n' > "$keys"
out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" supabase)"; rc=$?
assert_eq "$rc" "0" "succeeds for supabase backend"
l="$(cat "$log")"
assert_contains "$l" "env add NEXT_PUBLIC_SUPABASE_URL production" "sets prod supabase url"
assert_contains "$l" "env add NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY production" "sets prod publishable key"
assert_contains "$l" "env add NEXT_PUBLIC_SUPABASE_URL preview" "sets preview supabase url"
assert_contains "$l" "env add NEXT_PUBLIC_SUPABASE_URL development" "sets development supabase url"
rm -f "$log"

# Supabase backend, staging not provisioned -> preview/development env vars skipped, still succeeds
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
keys2="$(mktemp)"; printf 'SUPABASE_URL_PROD=https://p.supabase.co\nSUPABASE_PUBLISHABLE_KEY_PROD=pub_prod\nSUPABASE_STAGING_PROVISIONED=no\n' > "$keys2"
out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys2" supabase)"; rc=$?
assert_eq "$rc" "0" "succeeds even when supabase staging isn't provisioned"
assert_not_contains "$(cat "$log")" "env add NEXT_PUBLIC_SUPABASE_URL preview" "does not set a preview url with no staging project"
assert_contains "$out" "staging not provisioned" "explains why preview/development env vars were skipped"
rm -f "$log" "$keys" "$keys2"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_vercel_test.sh`
Expected: FAIL — current script's `supabase)` branch just prints an error and exits 1.

- [ ] **Step 3: Replace the `supabase)` branch in `scripts/wire-vercel.sh`**

```bash
  supabase)
    add_env NEXT_PUBLIC_SUPABASE_URL            production "${SUPABASE_URL_PROD:-}"            || exit 1
    add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY production "${SUPABASE_PUBLISHABLE_KEY_PROD:-}" || exit 1
    if [ "${SUPABASE_STAGING_PROVISIONED:-yes}" = "no" ]; then
      echo "vercel: staging not provisioned (best-effort Supabase branch creation didn't complete) — skipping preview/development env vars"
    else
      add_env NEXT_PUBLIC_SUPABASE_URL            preview    "${SUPABASE_URL_STAGING:-}"            || exit 1
      add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY preview    "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
      add_env NEXT_PUBLIC_SUPABASE_URL            development "${SUPABASE_URL_STAGING:-}"            || exit 1
      add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY development "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
    fi
    ;;
```

(This replaces the `echo "vercel: unknown backend 'supabase'..."; exit 1` two-liner from Task 2 — same `case` statement, same file.)

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_vercel_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/wire-vercel.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/wire-vercel.sh tests/wire_vercel_test.sh
git commit -m "$(cat <<'EOF'
feat: wire-vercel.sh sets Supabase env vars for backend=supabase

Sets NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY per
target — verified against the official create-next-app -e with-supabase
starter, which only reads these two (no secret/service_role key needed
for the default scaffold). When staging wasn't provisioned (branch-mode
best-effort failure), preview/development env vars are skipped with an
explanatory log line instead of failing.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: `scripts/wire-netlify.sh` — Supabase env vars

Same as Task 10, for Netlify contexts.

**Files:**
- Modify: `scripts/wire-netlify.sh`
- Test: `tests/wire_netlify_test.sh` (extend)

**Interfaces:**
- Consumes: same keys file shape as Task 10.
- Produces: same CLI contract as Task 3, `backend=supabase` implemented.

- [ ] **Step 1: Write the failing test**

Append to `tests/wire_netlify_test.sh` (before `exit "$FAILS"`):

```bash
# Supabase backend
log="$(mktemp)"
make_stub netlify "echo \"netlify \$*\" >> $log
case \"\$1\" in sites:list) echo '[]';; *) : ;; esac
exit 0"
keys="$(mktemp)"; printf 'SUPABASE_URL_PROD=https://p.supabase.co\nSUPABASE_PUBLISHABLE_KEY_PROD=pub_prod\nSUPABASE_URL_STAGING=https://s.supabase.co\nSUPABASE_PUBLISHABLE_KEY_STAGING=pub_staging\nSUPABASE_STAGING_PROVISIONED=yes\n' > "$keys"
out="$(NETLIFY_AUTH_TOKEN=t bash "$ROOT/scripts/wire-netlify.sh" acme "$keys" supabase)"; rc=$?
assert_eq "$rc" "0" "succeeds for supabase backend"
l="$(cat "$log")"
assert_contains "$l" "env:set NEXT_PUBLIC_SUPABASE_URL https://p.supabase.co --context production" "sets prod supabase url"
assert_contains "$l" "env:set NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY pub_prod --context production" "sets prod publishable key"
assert_contains "$l" "--context deploy-preview" "targets deploy-preview context"
assert_contains "$l" "--context branch-deploy" "targets branch-deploy context"
rm -f "$log" "$keys"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_netlify_test.sh`
Expected: FAIL — current `supabase)` branch errors out.

- [ ] **Step 3: Replace the `supabase)` branch in `scripts/wire-netlify.sh`**

```bash
  supabase)
    set_ctx NEXT_PUBLIC_SUPABASE_URL            production "${SUPABASE_URL_PROD:-}"            || exit 1
    set_ctx NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY production "${SUPABASE_PUBLISHABLE_KEY_PROD:-}" || exit 1
    if [ "${SUPABASE_STAGING_PROVISIONED:-yes}" = "no" ]; then
      echo "netlify: staging not provisioned (best-effort Supabase branch creation didn't complete) — skipping deploy-preview/branch-deploy env vars"
    else
      set_ctx NEXT_PUBLIC_SUPABASE_URL            deploy-preview "${SUPABASE_URL_STAGING:-}"            || exit 1
      set_ctx NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY deploy-preview "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
      set_ctx NEXT_PUBLIC_SUPABASE_URL            branch-deploy  "${SUPABASE_URL_STAGING:-}"            || exit 1
      set_ctx NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY branch-deploy  "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
    fi
    ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/wire_netlify_test.sh`
Expected: `FAILS` is `0`.

Also run: `shellcheck scripts/wire-netlify.sh` — expected: no output.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add scripts/wire-netlify.sh tests/wire_netlify_test.sh
git commit -m "$(cat <<'EOF'
feat: wire-netlify.sh sets Supabase env vars for backend=supabase

Same shape as the Vercel equivalent: NEXT_PUBLIC_SUPABASE_URL /
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY per context, skipping
deploy-preview/branch-deploy when staging wasn't provisioned.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Supabase-flavored `CLAUDE.md` / `DEV-PROD-WORKFLOW.md` / `.env.example`

Additive sibling templates (no directory restructuring — the existing Convex templates keep their current paths and filenames unchanged, minimizing blast radius on Task 5's and the existing tests' assumptions). `command/init-2env.md` (Task 14) picks which sibling to stamp based on `backend`.

**Files:**
- Create: `templates/CLAUDE.supabase.md`
- Create: `templates/docs/DEV-PROD-WORKFLOW.supabase.md`
- Create: `templates/env/.env.supabase.example`
- Test: `tests/templates_docs_test.sh` (extend), `tests/stamp_test.sh` unaffected (generic mechanism, no changes needed)

**Interfaces:**
- Consumes: same `{{VAR}}` stamping mechanism (`scripts/lib/stamp.sh`), no changes to that file.
- Produces: three new template files, all stampable with the existing `{{PROJECT_NAME}}`, `{{TEAM_KEY}}`, `{{AUTHOR_PREFIX}}`, `{{BUILD_CMD}}`, `{{LINT_CMD}}` vars used by the Convex versions, plus `{{SUPABASE_PROJECT_SLUG}}` (parallel to `{{CONVEX_PROJECT_SLUG}}`).

- [ ] **Step 1: Write the failing test**

Append to `tests/templates_docs_test.sh` (before `exit "$FAILS"`):

```bash
export SUPABASE_PROJECT_SLUG="maputo"
stamp_file "$ROOT/templates/CLAUDE.supabase.md" "$tmp/CLAUDE.supabase.md"; assert_eq "$?" "0" "CLAUDE.supabase.md stamps clean"
stamp_file "$ROOT/templates/docs/DEV-PROD-WORKFLOW.supabase.md" "$tmp/DEV-PROD-WORKFLOW.supabase.md"; assert_eq "$?" "0" "supabase workflow doc stamps clean"
stamp_file "$ROOT/templates/env/.env.supabase.example" "$tmp/.env.supabase.example"; assert_eq "$?" "0" "supabase env example stamps clean"
assert_contains "$(cat "$tmp/CLAUDE.supabase.md")" "supabase/migrations" "supabase CLAUDE.md documents the migrations directory"
assert_contains "$(cat "$tmp/DEV-PROD-WORKFLOW.supabase.md")" "staging" "supabase workflow doc explains staging deployment"
assert_contains "$(cat "$tmp/.env.supabase.example")" "NEXT_PUBLIC_SUPABASE_URL" "supabase env example documents the url var"
assert_contains "$(cat "$tmp/.env.supabase.example")" "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY" "supabase env example documents the publishable key var"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_docs_test.sh`
Expected: FAIL — the three new files don't exist yet.

- [ ] **Step 3: Create the three templates**

`templates/CLAUDE.supabase.md`:

```markdown
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
```

`templates/docs/DEV-PROD-WORKFLOW.supabase.md`:

```markdown
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
```

`templates/env/.env.supabase.example`:

```bash
# Supabase project: {{SUPABASE_PROJECT_SLUG}}
# Get these from your project settings > API (https://app.supabase.com/project/_/settings/api).
# Both are safe to expose to the browser (NEXT_PUBLIC_*).
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=
# CI/CD migration connection strings live in GitHub Secrets, never here:
#   SUPABASE_DB_URL_STAGING  (staging project/branch)
#   SUPABASE_DB_URL_PROD     (production project)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/templates_docs_test.sh`
Expected: `FAILS` is `0`.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add templates/CLAUDE.supabase.md templates/docs/DEV-PROD-WORKFLOW.supabase.md templates/env/.env.supabase.example tests/templates_docs_test.sh
git commit -m "$(cat <<'EOF'
feat: add Supabase-flavored CLAUDE.md / DEV-PROD-WORKFLOW.md / .env.example

Additive sibling files (CLAUDE.supabase.md etc.) rather than
restructuring the existing Convex template paths — command/init-2env.md
picks the right sibling to stamp based on the chosen backend. Covers
both Supabase sub-modes (two projects / persistent branch) in the
workflow doc, including the manual follow-up for a best-effort branch
creation that didn't complete.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: `command/init-2env.md` — backend selection and Phase 2 branching

Wires everything from Parts A and B into the orchestration command itself: new interview questions, Phase 0 preflight flag, Phase 2 steps branching on `backend`, updated hard rules.

**Files:**
- Modify: `command/init-2env.md`
- Test: `tests/command_lint_test.sh` (extend)

**Interfaces:**
- Consumes: `scripts/preflight.sh --deploy <target> --backend <backend>` (Task 1/11), `scripts/setup-convex.sh ... --team <team>` (Task 4), `scripts/setup-supabase.sh <slug> --mode <mode> --keys-file <path>` (Tasks 6/7), `scripts/set-github-secrets.sh <repo> <keys> [backend]` (Task 9), `scripts/wire-vercel.sh`/`wire-netlify.sh <name> <keys> [backend]` (Tasks 2/3/10/11), `templates/CLAUDE.supabase.md` etc. (Task 12).
- Produces: the full `/init-2env` command behavior end users invoke.

- [ ] **Step 1: Write the failing test**

Append to `tests/command_lint_test.sh` (before `exit "$FAILS"`):

```bash
for s in setup-supabase; do
  assert_contains "$c" "$s" "references $s script"
done
assert_contains "$c" "Database" "interview asks about the database/backend choice"
assert_contains "$c" "Supabase" "interview mentions Supabase as an option"
assert_contains "$c" "persistent branch" "interview mentions the persistent-branch isolation mode"
assert_contains "$c" "CONVEX_TEAM" "documents the Convex team-selection fix"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/command_lint_test.sh`
Expected: FAIL — none of these strings exist in `command/init-2env.md` yet.

- [ ] **Step 3: Rewrite `command/init-2env.md`**

Replace the full file with:

```markdown
---
description: Bootstrap a brand-new Next.js+Convex-or-Supabase project with two environments (main=prod, dev=staging), GitHub CI, Vercel/Netlify, and a Linear team. Usage: /init-2env
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion, mcp__plugin_linear_linear__list_teams, mcp__plugin_linear_linear__list_projects, mcp__plugin_linear_linear__list_issue_statuses, Agent
---

Bootstrap a two-environment (main=production, dev=staging) Next.js + (Convex or Supabase) project **from scratch** in the current empty directory. This repo's `scripts/` and `templates/` (path: the init-2env source repo — resolve it from where this command was synced, or ask) do the mechanical work.

Work top to bottom. There is exactly ONE confirmation gate (end of Phase 1). Preflight may stop earlier. On any Phase 2 failure, STOP, report what was created, and offer cleanup — never continue silently.

## Phase 0 — Preflight
- Run `scripts/preflight.sh --deploy <chosen> --backend <chosen>` (deploy default vercel, backend default convex). If it exits non-zero, print the MISSING lines verbatim and STOP — tell the user exactly what to log in / export. Do not attempt logins yourself.

## Phase 1 — Interview + plan
Ask only what can't be inferred (use `AskUserQuestion`):
1. Project name → derive slug (kebab), repo name, backend project slug, Vercel/Netlify name, suggested Linear key (uppercase initials, e.g. "Maputo" → MAP).
2. **Database**: Convex (default) or Supabase.
   - If Supabase: **Environment isolation** — two Supabase projects + SQL migrations (recommended), or a single project + persistent branch (best-effort; may require a manual follow-up step if the CLI can't fully automate it — see Phase 3).
3. GitHub repo private or public.
4. Deploy target: Vercel (default) or Netlify.
5. Confirm Linear team key and AUTHOR_PREFIX (initials from `git config user.name`).
6. **Convex only**: if the account belongs to more than one Convex team (the user will know; there's no way to enumerate this via the CLI), ask for the team slug (`CONVEX_TEAM`). If they have only one team, skip this question — it's auto-detected.
7. **Supabase only**: run `supabase orgs list -o json` yourself right now (read-only, no side effects) to check org count — do this here, not in Phase 2, because Phase 2 has no further prompts and the full plan below needs to state which org will be used. If exactly one org, use it silently. If more than one, ask which org to use (`--org-id`); if zero, tell the user to create one first (same message `scripts/setup-supabase.sh` would give) and stop.

Detect build/lint commands from the scaffold's `package.json` (default `npm run build` / `npm run lint`).

Print the FULL PLAN: repo (name+visibility), backend resources (Convex project + staging deployment, or Supabase project(s)/branch), GitHub secrets + environments, Linear team+project, deploy host + the exact env vars per target. Then ONE `AskUserQuestion`: **Execute all** / Edit / Cancel. Proceed only on "Execute all".

## Phase 2 — Autonomous execution (no further prompts)
1. **Scaffold**:
   - Convex: run the official Next.js+Convex starter into the current dir (e.g. `npm create convex@latest -- -t nextjs` or the current recommended command — verify the flag with the starter's docs).
   - Supabase: run `npx create-next-app@latest -e with-supabase` into the current dir (verify the flag with the starter's docs).
   Then `git init` if needed and an initial commit.
2. **Backend provisioning**: `keys=$(mktemp)`.
   - Convex: `scripts/setup-convex.sh <slug> --keys-file "$keys" [--team <team>]`. Mints the prod+staging deploy keys, writes them only to `"$keys"`.
   - Supabase: `scripts/setup-supabase.sh <slug> --mode <projects|branch> --keys-file "$keys" [--org-id <id>]`. Creates the project(s)/branch, writes refs/URLs/publishable keys/db connection strings only to `"$keys"`. If mode is `branch` and staging provisioning was best-effort and didn't complete, this is **not fatal** — proceed, and note it for Phase 3's summary (the keys file records `SUPABASE_STAGING_PROVISIONED=no`).
   This is the only place the keys file is created.
3. **GitHub**: `scripts/create-github-repo.sh <name> <vis>` → capture repo URL and `owner/repo`.
4. **Stamp templates** (export TEAM_KEY, TEAM_NAME, AUTHOR_PREFIX, PROJECT_NAME, BUILD_CMD, LINT_CMD, and `CONVEX_PROJECT_SLUG` or `SUPABASE_PROJECT_SLUG` depending on backend, then use `stamp_dir`/`stamp_file` from `scripts/lib/stamp.sh`):
   - `templates/github-workflows/convex-deploy-{dev,prod}.yml` (Convex) or `templates/github-workflows/supabase-deploy-{dev,prod}.yml` (Supabase) → `.github/workflows/`.
   - `templates/claude-commands/*` → `.claude/commands/` (backend-agnostic, unchanged).
   - `templates/CLAUDE.md` (Convex) or `templates/CLAUDE.supabase.md` (Supabase) → `./CLAUDE.md`.
   - `templates/docs/DEV-PROD-WORKFLOW.md` (Convex) or `templates/docs/DEV-PROD-WORKFLOW.supabase.md` (Supabase) → `./docs/DEV-PROD-WORKFLOW.md`.
   - `templates/env/.env.example` (Convex) or `templates/env/.env.supabase.example` (Supabase) → `./.env.example`.
   - Commit the stamped files.
5. **Secrets**: `scripts/set-github-secrets.sh owner/repo "$keys" [backend]` — sets the backend's GitHub Actions secrets (Convex: `CONVEX_DEPLOY_KEY_PROD`/`_STAGING`; Supabase: `SUPABASE_DB_URL_PROD`/`_STAGING`, skipping the staging one if not provisioned) plus the `staging`/`production` GitHub environments. This step reads `"$keys"` but does NOT delete it — the deploy-host step (7) still needs it.
6. **Linear**: optionally discover existing teams first with `mcp__plugin_linear_linear__list_teams` (read-only). Then create the new team **via the Linear GraphQL API using LINEAR_API_KEY**: `curl -sS -X POST https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" -d '{"query":"mutation{ teamCreate(input:{name:\"<TEAM_NAME>\",key:\"<TEAM_KEY>\"}){ success team{ id name key } } }"}'` with the confirmed key; then create a project named after the app with the `projectCreate` mutation (passing the new team id in `teamIds`); note the returned ids/urls. If team creation fails (plan limit), STOP and offer "project inside an existing team" (list via `list_projects`).
7. **Deploy host**: `scripts/wire-vercel.sh <name> "$keys" [backend]` (or `wire-netlify.sh <site> "$keys" [backend]` for Netlify). `backend` defaults to `convex` when omitted; pass it explicitly for Supabase. This is the last consumer of `"$keys"` — after this step nothing else needs it.
   - **Convex**: write the zero-touch build config so the Convex build command is set with no manual dashboard step. The build command injects `NEXT_PUBLIC_CONVEX_URL` at build time via `--cmd-url-env-var-name` (correct per environment because `CONVEX_DEPLOY_KEY` selects the deployment), so no URL env var is stored:
     - **Vercel**: write `vercel.json` at the project root:
       ```json
       { "buildCommand": "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL" }
       ```
     - **Netlify**: write `netlify.toml` at the project root with a `[build]` section:
       ```toml
       [build]
       command = "npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL"
       publish = ".next"
       ```
   - **Supabase**: no build-command injection is needed — `NEXT_PUBLIC_SUPABASE_URL`/`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are plain, stable env vars set directly by `wire-vercel.sh`/`wire-netlify.sh`. Do not write a custom build command for Supabase; the framework preset's default build is enough.
   Commit `vercel.json`/`netlify.toml` (Convex only) together with the stamped files from step 4 (or in its own small commit if step 4 already ran) so the build command is live with no manual dashboard step.
8. **Cleanup**: `rm -f "$keys"` — delete the keys file now that both the GitHub secrets (step 5) and the deploy-host env vars (step 7) are set. This is the single point where the file is removed; no earlier step deletes it.

## Phase 3 — Summary
Print: repo URL, backend dashboard URL(s) (Convex production+staging, or the Supabase project(s)/branch), Vercel/Netlify URL, Linear team+project URLs, and any single manual step left (e.g. connect the repo in the Vercel dashboard if OAuth was needed). **If Supabase mode was `branch` and staging provisioning was best-effort and didn't complete**, print the manual follow-up: connect this repo in Supabase → Settings → Integrations → GitHub, create the persistent `dev` branch from the dashboard (or re-run `supabase branches create dev --persistent --project-ref <ref>`), then set `SUPABASE_DB_URL_STAGING` and the preview/development env vars by hand. Confirm nothing was pushed/charged beyond the approved plan.

## Hard rules
- One confirmation gate only; Preflight is the sole earlier stop. Never log in on the user's behalf. Never print or write secret values. On failure, stop + report + offer cleanup; never leave half-created resources silently.
- Convex: if the account has multiple teams, `CONVEX_TEAM` must be asked/set explicitly (no CLI-side team listing exists) — never let `convex project create` hit its interactive team prompt.
- Supabase: DB passwords are only capturable at project-creation time — never attempt to "resume" into an already-existing project by that name; stop and offer cleanup instead (`scripts/setup-supabase.sh` already enforces this).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `STUB_BIN="$(mktemp -d)" && PATH="$STUB_BIN:$PATH" ROOT="$(pwd)" bash tests/command_lint_test.sh`
Expected: `FAILS` is `0`.

- [ ] **Step 5: Run full suite and commit**

Run: `bash tests/run.sh` — expected: `ALL TESTS PASSED`.

```bash
git add command/init-2env.md tests/command_lint_test.sh
git commit -m "$(cat <<'EOF'
feat: init-2env.md gains the Supabase backend choice and wires the fixes

Phase 1 now asks Convex-vs-Supabase (and, for Supabase, the isolation
sub-mode); Phase 0/2 branch on backend for preflight, provisioning,
secrets, templates, and deploy-host wiring. Hard rules document the two
non-obvious constraints this plan surfaced: Convex has no team-listing
subcommand (CONVEX_TEAM must be explicit when ambiguous), and Supabase
DB passwords are only capturable at project-creation time (no resume
into an existing same-named project).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: `docs/E2E-CHECKLIST.md` — Supabase sections

Manual validation checklist additions, parallel to the existing Convex section.

**Files:**
- Modify: `docs/E2E-CHECKLIST.md`

**Interfaces:**
- Consumes: nothing (a docs-only checklist, not exercised by automated tests).
- Produces: nothing other agents depend on.

- [ ] **Step 1: Add the Supabase sections**

After the existing `### (b) Convex project — two deployments` section in `docs/E2E-CHECKLIST.md`, add:

```markdown
### (b′) Supabase — two projects mode

- [ ] The Supabase dashboard shows two projects: `<slug>-prod` and `<slug>-staging`, each with its own ref, URL, and publishable key.
- [ ] `supabase/migrations/` exists in the repo; a trivial migration (`supabase migration new e2e_test`) committed to `dev` and pushed triggers `supabase-deploy-dev.yml`, and the staging project shows the new migration applied (check via `supabase migration list --db-url "$SUPABASE_DB_URL_STAGING"` or the dashboard's migration history).
- [ ] `main` is untouched — the production project does NOT show the new migration after a `dev`-only push.
- [ ] GitHub secrets `SUPABASE_DB_URL_PROD` and `SUPABASE_DB_URL_STAGING` exist (values not visible, but listed in repo Settings → Secrets).

### (b″) Supabase — persistent branch mode

- [ ] The Supabase dashboard shows one project (production) and, if branch creation succeeded, a persistent branch named `dev` for staging.
- [ ] **If branch creation succeeded**: pushing a migration to `dev` applies it to the branch, not to the parent project; `main` (production) is unaffected.
- [ ] **If branch creation failed (best-effort)**: confirm the run still completed (exit 0), `SUPABASE_STAGING_PROVISIONED=no` behavior was observed (preview/development env vars skipped, staging GitHub secret skipped), and the manual follow-up instruction was printed in Phase 3. Follow it manually (connect GitHub integration, create the branch from the dashboard) and confirm the app then works end-to-end once `SUPABASE_DB_URL_STAGING` and the preview/development env vars are set by hand.
```

And extend the `## Teardown` section:

```markdown
- [ ] Delete the Supabase project(s) (and persistent branch, if created).
```

(alongside the existing Convex teardown line, not replacing it — the checklist should list whichever backend was actually exercised in that run).

- [ ] **Step 2: Commit**

```bash
git add docs/E2E-CHECKLIST.md
git commit -m "$(cat <<'EOF'
docs: add Supabase sections to the E2E validation checklist

Covers both sub-modes (two projects, persistent branch), including the
best-effort branch-creation-failed path this plan's design explicitly
allows for.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: `README.md` — updated prerequisites and layout

**Files:**
- Modify: `README.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the prerequisites and layout sections**

In the `## One-time prerequisites` section, add a `jq` bullet and update the Convex/Vercel/Netlify bullets to mention the new checks, and add a Supabase bullet:

```markdown
- **`jq`**: required (used by Supabase provisioning and by the Netlify site-idempotency check).
- **GitHub**: `gh auth login` (checked via `gh auth status`).
- **Database — Convex** (default): logged in (`npx convex` / `convex` CLI available) or a `CONVEX_DEPLOY_KEY` already exported. If your account belongs to more than one Convex team, export `CONVEX_TEAM` (there's no CLI command to list teams, so this can't be auto-detected).
- **Database — Supabase** (optional, chosen at the Phase 1 interview): `supabase` CLI logged in, or `SUPABASE_ACCESS_TOKEN` exported.
- **Deploy host**: `VERCEL_TOKEN` exported (or `vercel login`) for Vercel — the default — or `NETLIFY_AUTH_TOKEN` exported (or `netlify login`) if you choose Netlify.
- **Linear**: `LINEAR_API_KEY` exported (required). The command creates the Linear team and project via the Linear GraphQL API using this key, so preflight blocks if it is missing. The read-only Linear MCP is still used for discovery (listing existing teams/projects) when available.
```

In the `## Repo layout` section, update the `scripts/` and `templates/` bullets:

```markdown
templates/       Files stamped into the new project:
  github-workflows/   Convex deploy CI or Supabase migration CI (dev → staging, main → production), whichever backend was chosen.
  claude-commands/     /issue and /close-issue, stamped into .claude/commands/ (backend-agnostic).
  env/                 .env.example (Convex or Supabase variant).
  CLAUDE.md / CLAUDE.supabase.md      Project-level CLAUDE.md for the new repo, per backend.
  docs/                DEV-PROD-WORKFLOW.md (Convex or Supabase variant).
scripts/         One script per responsibility (preflight, setup-convex,
                 setup-supabase, create-github-repo, set-github-secrets,
                 wire-vercel, wire-netlify, sync) plus scripts/lib/stamp.sh.
```

Also update the top-level description line and the "What it does" section to mention the database choice, e.g. change:

```markdown
`/init-2env` bootstraps a brand-new **Next.js + Convex** project from scratch,
```

to:

```markdown
`/init-2env` bootstraps a brand-new **Next.js + Convex or Supabase** project from scratch,
```

and add a bullet under "What it does":

```markdown
- **Database choice**: Convex (default), or Supabase — either two separate projects with SQL migrations, or a single project with a persistent branch for staging (best-effort; may need one manual follow-up step, printed at the end if so).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: update README for the Supabase backend and new prerequisites

Documents jq as a new prerequisite, NETLIFY_AUTH_TOKEN as a Netlify
auth alternative to interactive login, CONVEX_TEAM for multi-team
accounts, and the Supabase backend choice with its two sub-modes.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-07-07-init-2env-hardening-and-supabase-design.md`):
- §3 fixes #1–#5 → Tasks 1–5. Fix #6 (Netlify argv limitation) is explicitly a no-op, documented in Task 3's rewritten comment. Fix #7 (repo's own CI) is explicitly out of scope, per the spec.
- §4.1–4.3 (backend dimension, preflight, provisioning) → Tasks 1, 6, 7, 13.
- §4.4 (CI templates) → Task 8.
- §4.5 (deploy host wiring) → Tasks 10, 11 (plus Task 9 for the GitHub-secrets half of the same concern, which the spec's §4.5 table implied but didn't name as a separate file — added here since `set-github-secrets.sh` is the other consumer of the keys file besides the deploy host).
- §4.6 (conditional templates) → Task 12.
- §4.7 (testing strategy) → covered inline in every task's own test step, not deferred to a separate task.
- §4.8 (E2E checklist) → Task 14.
- §6 (out of scope) → respected: no Auth/RLS scaffolding added, no per-PR ephemeral preview branches, no repo CI, no N-backend plugin abstraction (three modes are hardcoded branches throughout, as specified).

**Corrections made during planning that refine (not contradict) the spec**, both because the spec deliberately left exact flag/field names to this stage:
- Convex team resolution: the spec said "list and ask/require when ambiguous"; the CLI has no listing subcommand (verified), so this plan implements the "require" half only (`--team`/`CONVEX_TEAM`), documented in Task 4 and in `command/init-2env.md`'s hard rules.
- Supabase key naming: the spec's §4.5 table used `NEXT_PUBLIC_SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY`; verified (via the CLI's own source and the official starter) that current projects use `publishable`/`secret`-type keys and the official starter only needs `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` — no service-role/secret key is wired to the deploy host at all. This plan's env var names reflect that throughout (Tasks 6, 10, 11, 12).

**Placeholder scan:** no "TBD"/"add appropriate error handling"/"similar to Task N" phrases; every step shows complete code or an exact command with expected output.

**Type/name consistency check:** keys-file variable names (`SUPABASE_REF_PROD`, `SUPABASE_URL_PROD`, `SUPABASE_PUBLISHABLE_KEY_PROD`, `SUPABASE_DB_URL_PROD`, `SUPABASE_STAGING_PROVISIONED`, and their `_STAGING` counterparts) are identical across Tasks 6, 7, 9, 10, 11, 12, 13 — verified by re-reading each task's code against the others while writing this plan. Function names introduced in Task 6 (`create_project`, `write_env_block`, `extract_public_key`, `find_project_ref`, `gen_db_password`) are only reused within the same file by Task 7; no other task calls them directly.
