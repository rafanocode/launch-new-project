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

exit "$FAILS"
