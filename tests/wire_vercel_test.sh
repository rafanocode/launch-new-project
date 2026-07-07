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

# supabase backend not yet implemented here (Task 9 in the plan replaces this branch) -> errors loudly BEFORE calling convex's add_env, doesn't fall through
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" supabase 2>&1)"; rc=$?
assert_fail_exit "$rc" "supabase backend placeholder exits non-zero rather than silently reusing convex handling"
assert_not_contains "$(cat "$log")" "CONVEX_DEPLOY_KEY" "does not fall through to convex's add_env calls"
rm -f "$log"

# unknown backend -> also errors loudly before any add_env call
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" bogus 2>&1)"; rc=$?
assert_fail_exit "$rc" "unknown backend exits non-zero"
assert_not_contains "$(cat "$log")" "CONVEX_DEPLOY_KEY" "does not fall through to convex's add_env calls"
rm -f "$log"

rm -f "$keys"
exit "$FAILS"
