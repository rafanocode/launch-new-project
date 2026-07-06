#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

# All good: gh authed, convex present, vercel present
make_stub gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'
make_stub convex 'exit 0'
make_stub vercel 'exit 0'

out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel)"; rc=$?
assert_eq "$rc" "0" "exit 0 when all present"
assert_contains "$out" "OK gh" "reports gh ok"
assert_contains "$out" "OK convex" "reports convex ok"
assert_contains "$out" "OK vercel" "reports vercel ok"

# gh missing auth -> fatal
make_stub gh 'case "$1 $2" in "auth status") exit 1;; *) exit 0;; esac'
out="$(LINEAR_API_KEY=x bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when gh not authed"
assert_contains "$out" "MISSING gh" "reports gh missing with hint"

# CLIs present but LINEAR_API_KEY unset -> fatal (needed to create Linear team/project)
make_stub gh 'case "$1 $2" in "auth status") exit 0;; *) exit 0;; esac'
out="$(env -u LINEAR_API_KEY bash "$ROOT/scripts/preflight.sh" --deploy vercel 2>&1)"; rc=$?
assert_fail_exit "$rc" "non-zero when LINEAR_API_KEY unset"
assert_contains "$out" "MISSING linear" "reports linear missing"

exit "$FAILS"
