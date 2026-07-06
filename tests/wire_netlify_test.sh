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
