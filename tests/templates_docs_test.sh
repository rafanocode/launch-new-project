#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"
export PROJECT_NAME="Maputo" TEAM_KEY="MAP" AUTHOR_PREFIX="RR" BUILD_CMD="npm run build" LINT_CMD="npm run lint" CONVEX_PROJECT_SLUG="maputo"
stamp_file "$ROOT/templates/CLAUDE.md" "$tmp/CLAUDE.md"; assert_eq "$?" "0" "CLAUDE.md stamps clean"
stamp_dir "$ROOT/templates/docs" "$tmp/docs"; assert_eq "$?" "0" "workflow doc stamps clean"
assert_contains "$(cat "$tmp/CLAUDE.md")" "dev" "CLAUDE.md documents dev/main flow"
assert_contains "$(cat "$tmp/docs/DEV-PROD-WORKFLOW.md")" "staging" "workflow doc explains staging deployment"
rm -rf "$tmp"
exit "$FAILS"
