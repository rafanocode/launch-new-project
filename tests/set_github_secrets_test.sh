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
