#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
mkdir -p "$ROOT/command"; printf '# init-2env\n' > "$ROOT/command/init-2env.md"
home="$(mktemp -d)"
out="$(CLAUDE_HOME="$home/.claude" bash "$ROOT/scripts/sync.sh")"; rc=$?
assert_eq "$rc" "0" "succeeds"
assert_contains "$out" "$home/.claude/commands/init-2env.md" "prints destination"
assert_eq "$(cat "$home/.claude/commands/init-2env.md")" "# init-2env" "copies content"
rm -rf "$home"
exit "$FAILS"
