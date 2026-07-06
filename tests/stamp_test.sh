#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"

tmp="$(mktemp -d)"
printf 'hello {{NAME}}, key={{TEAM_KEY}}\n' > "$tmp/in.txt"

# happy path
NAME="world" TEAM_KEY="MAP" stamp_file "$tmp/in.txt" "$tmp/out.txt"
assert_eq "$(cat "$tmp/out.txt")" "hello world, key=MAP" "substitutes all markers"

# missing var -> non-zero, marker preserved, listed on stderr
NAME="world" stamp_file "$tmp/in.txt" "$tmp/out2.txt" 2>"$tmp/err.txt"; rc=$?
assert_fail_exit "$rc" "fails when a marker is unresolved"
assert_contains "$(cat "$tmp/out2.txt")" "{{TEAM_KEY}}" "leaves unresolved marker in output"
assert_contains "$(cat "$tmp/err.txt")" "{{TEAM_KEY}}" "reports unresolved marker on stderr"

rm -rf "$tmp"
exit "$FAILS"
