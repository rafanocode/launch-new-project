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
assert_contains "$out" "npx convex deploy" "prints the Convex build-command note for backend=convex"
rm -f "$log"

# Real failure (e.g. bad auth) must NOT be swallowed
make_stub vercel 'case "$1 $2" in "env add") exit 1;; "link") exit 1;; *) exit 0;; esac'
out="$(VERCEL_TOKEN=bad bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "real vercel failure exits non-zero, not silently continuing"

# unknown backend -> also errors loudly before any add_env call
log="$(mktemp)"
make_stub vercel "echo \"vercel \$*\" >> $log; exit 0"
out="$(VERCEL_TOKEN=t bash "$ROOT/scripts/wire-vercel.sh" acme "$keys" bogus 2>&1)"; rc=$?
assert_fail_exit "$rc" "unknown backend exits non-zero"
assert_not_contains "$(cat "$log")" "CONVEX_DEPLOY_KEY" "does not fall through to convex's add_env calls"
rm -f "$log"

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
assert_not_contains "$out" "npx convex deploy" "does not print the Convex build-command note for backend=supabase"
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

rm -f "$keys"
exit "$FAILS"
