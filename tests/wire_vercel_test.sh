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
