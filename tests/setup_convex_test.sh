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
