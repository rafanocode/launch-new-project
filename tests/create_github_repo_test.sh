#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

work="$(mktemp -d)"; cd "$work" || exit 1
git init -q; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init

make_stub gh '
case "$1 $2" in
  "repo create") echo "created"; exit 0;;
  "repo view") echo "https://github.com/me/acme"; exit 0;;
  *) exit 0;;
esac'

# Real git is used for local branch/push operations; only gh is stubbed.
out="$(bash "$ROOT/scripts/create-github-repo.sh" acme private)"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$out" "github.com/me/acme" "prints repo URL"
assert_contains "$(git branch --list dev)" "dev" "creates dev branch"
cd /; rm -rf "$work"
exit "$FAILS"
