#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"

export TEAM_KEY="MAP" TEAM_NAME="Maputo" AUTHOR_PREFIX="RR" BUILD_CMD="npm run build" LINT_CMD="npm run lint"
stamp_dir "$ROOT/templates/claude-commands" "$tmp/cmds"
assert_eq "$?" "0" "command templates stamp with no leftover markers"

issue="$(cat "$tmp/cmds/issue.md")"
assert_contains "$issue" 'MAP-\d+' "issue.md uses derived team key in the ID regex"
assert_contains "$issue" "RR-MAP" "issue.md uses author+team prefix in branch format"
assert_contains "$issue" "convex/schema.ts" "issue.md has Convex schema note (not Supabase)"

close="$(cat "$tmp/cmds/close-issue.md")"
assert_contains "$close" "gh pr create --base dev" "close-issue is PR-based"
assert_contains "$close" "npm run build" "close-issue uses detected build command"
case "$close" in *"migration"*|*"Supabase"*) echo "  FAIL: close-issue still mentions migrations/Supabase"; FAILS=$((FAILS+1));; *) echo "  ok: no SQL-migration leftovers";; esac
rm -rf "$tmp"
exit "$FAILS"
