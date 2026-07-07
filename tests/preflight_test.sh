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

# jq missing -> fatal: create a jq stub that fails so command can find it but can't run it
rm -f "$STUB_BIN/jq"
make_stub jq 'exit 1' # shadow any system jq with a stub that fails execution
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when jq missing"
assert_contains "$out" "MISSING jq" "reports jq missing"
rm -f "$STUB_BIN/jq"
make_stub jq 'exit 0' # restore working jq stub

# CLIs present but LINEAR_API_KEY unset -> fatal (needed to create Linear team/project)
out="$(env -u LINEAR_API_KEY bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when LINEAR_API_KEY unset"
assert_contains "$out" "MISSING linear" "reports linear missing"

# --backend supabase: supabase binary truly absent -> fatal
# Restrict PATH to STUB_BIN + core system dirs so a real supabase CLI installed via
# Homebrew (e.g. /opt/homebrew/bin) on the dev machine doesn't leak into the test.
rm -f "$STUB_BIN/supabase"
out="$(LINEAR_API_KEY=x PATH="$STUB_BIN:/bin:/usr/bin" bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when backend=supabase and supabase CLI missing"
assert_contains "$out" "MISSING supabase" "reports supabase cli missing"

# --backend supabase: supabase CLI present, SUPABASE_ACCESS_TOKEN unset, no session -> fatal
make_stub supabase 'case "$1 $2" in "projects list") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x env -u SUPABASE_ACCESS_TOKEN bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when backend=supabase and no supabase session"
assert_contains "$out" "MISSING supabase" "reports supabase not authed"

# --backend supabase: SUPABASE_ACCESS_TOKEN set and the CLI actually verifies it via projects list -> OK
make_stub supabase 'case "$1 $2" in "projects list") [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] && exit 0 || exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x SUPABASE_ACCESS_TOKEN=tok bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase)"; rc=$?
assert_eq "$rc" "0" "exit 0 when backend=supabase and SUPABASE_ACCESS_TOKEN set"
assert_contains "$out" "OK supabase" "reports supabase ok"

# --backend supabase: SUPABASE_ACCESS_TOKEN set but invalid (projects list fails regardless) -> fatal
# Regression guard: catches a reintroduced `[ -n "$TOKEN" ] && return 0` short-circuit,
# which would report OK here even though the token doesn't actually work.
make_stub supabase 'case "$1 $2" in "projects list") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x SUPABASE_ACCESS_TOKEN=bad-tok bash "$ROOT/scripts/preflight.sh" --deploy vercel --backend supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when backend=supabase and SUPABASE_ACCESS_TOKEN is set but invalid"
assert_contains "$out" "MISSING supabase" "reports supabase not authed despite token present"

# --deploy netlify: happy path, netlify authed
make_stub netlify 'case "$1" in status) exit 0;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy netlify)"; rc=$?
assert_eq "$rc" "0" "exit 0 when netlify authed"
assert_contains "$out" "OK netlify" "reports netlify ok"

# --deploy netlify: binary present but not authed (status fails) -> fatal
make_stub netlify 'case "$1" in status) exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x env -u NETLIFY_AUTH_TOKEN bash "$ROOT/scripts/preflight.sh" --deploy netlify 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when netlify binary present but not authed"
assert_contains "$out" "MISSING netlify" "reports netlify not authed"

# --deploy netlify: NETLIFY_AUTH_TOKEN set but invalid (status fails regardless) -> fatal
# Regression guard: catches a reintroduced `[ -n "$TOKEN" ] && return 0` short-circuit,
# which would report OK here even though the token doesn't actually work.
make_stub netlify 'case "$1" in status) exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x NETLIFY_AUTH_TOKEN=bad-tok bash "$ROOT/scripts/preflight.sh" --deploy netlify 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when netlify NETLIFY_AUTH_TOKEN is set but invalid"
assert_contains "$out" "MISSING netlify" "reports netlify not authed despite token present"

exit "$FAILS"
