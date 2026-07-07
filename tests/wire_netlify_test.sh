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
assert_not_contains "$l" "--auth" "does not pass the token on argv (NETLIFY_AUTH_TOKEN env var only)"
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

# unknown backend -> also errors loudly before any env:set call
log="$(mktemp)"
make_stub netlify "echo \"netlify \$*\" >> $log
case \"\$1\" in
  sites:list) echo '[]';;
  sites:create) exit 0;;
  *) : ;;
esac
exit 0"
out="$(NETLIFY_AUTH_TOKEN=t bash "$ROOT/scripts/wire-netlify.sh" acme "$keys" bogus 2>&1)"; rc=$?
assert_fail_exit "$rc" "unknown backend exits non-zero"
assert_not_contains "$(cat "$log")" "CONVEX_DEPLOY_KEY" "does not fall through to convex's env:set calls"
rm -f "$log"

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

rm -f "$keys"
exit "$FAILS"
