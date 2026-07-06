#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
home="$(mktemp -d)"
out="$(CLAUDE_HOME="$home/.claude" bash "$ROOT/scripts/sync.sh")"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$out" "$home/.claude/commands/init-2env.md" "prints destination"
assert_eq "$(cat "$home/.claude/commands/init-2env.md")" "$(cat "$ROOT/command/init-2env.md")" "copies content"
rm -rf "$home"
exit "$FAILS"
