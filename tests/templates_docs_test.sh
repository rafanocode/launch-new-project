#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"
export PROJECT_NAME="Maputo" TEAM_KEY="MAP" AUTHOR_PREFIX="RR" BUILD_CMD="npm run build" LINT_CMD="npm run lint" CONVEX_PROJECT_SLUG="maputo" SUPABASE_PROJECT_SLUG="maputo"
stamp_file "$ROOT/templates/CLAUDE.md" "$tmp/CLAUDE.md"; assert_eq "$?" "0" "CLAUDE.md stamps clean"
stamp_dir "$ROOT/templates/docs" "$tmp/docs"; assert_eq "$?" "0" "workflow doc stamps clean"
assert_contains "$(cat "$tmp/CLAUDE.md")" "dev" "CLAUDE.md documents dev/main flow"
assert_contains "$(cat "$tmp/docs/DEV-PROD-WORKFLOW.md")" "staging" "workflow doc explains staging deployment"

stamp_file "$ROOT/templates/CLAUDE.supabase.md" "$tmp/CLAUDE.supabase.md"; assert_eq "$?" "0" "CLAUDE.supabase.md stamps clean"
stamp_file "$ROOT/templates/docs/DEV-PROD-WORKFLOW.supabase.md" "$tmp/DEV-PROD-WORKFLOW.supabase.md"; assert_eq "$?" "0" "supabase workflow doc stamps clean"
stamp_file "$ROOT/templates/env/.env.supabase.example" "$tmp/.env.supabase.example"; assert_eq "$?" "0" "supabase env example stamps clean"
assert_contains "$(cat "$tmp/CLAUDE.supabase.md")" "supabase/migrations" "supabase CLAUDE.md documents the migrations directory"
assert_contains "$(cat "$tmp/DEV-PROD-WORKFLOW.supabase.md")" "staging" "supabase workflow doc explains staging deployment"
assert_contains "$(cat "$tmp/.env.supabase.example")" "NEXT_PUBLIC_SUPABASE_URL" "supabase env example documents the url var"
assert_contains "$(cat "$tmp/.env.supabase.example")" "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY" "supabase env example documents the publishable key var"

rm -rf "$tmp"
exit "$FAILS"
