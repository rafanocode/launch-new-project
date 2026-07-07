#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/scripts/lib/stamp.sh"
tmp="$(mktemp -d)"

CONVEX_PROJECT_SLUG="acme" stamp_dir "$ROOT/templates/env" "$tmp/env"
assert_eq "$?" "0" "env template stamps with no leftover markers"

# Workflows contain no {{ }} markers and reference the two secrets
for f in convex-deploy-dev.yml convex-deploy-prod.yml; do
  stamp_file "$ROOT/templates/github-workflows/$f" "$tmp/$f"
  assert_eq "$?" "0" "$f stamps clean"
done
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "CONVEX_DEPLOY_KEY_STAGING" "dev workflow uses staging key"
assert_contains "$(cat "$tmp/convex-deploy-prod.yml")" "CONVEX_DEPLOY_KEY_PROD" "prod workflow uses prod key"
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "branches: [dev]" "dev workflow triggers on dev"
assert_contains "$(cat "$tmp/convex-deploy-prod.yml")" "branches: [main]" "prod workflow triggers on main"
assert_contains "$(cat "$tmp/convex-deploy-dev.yml")" "environment: staging" "dev workflow declares the staging GitHub Environment"

for f in supabase-deploy-dev.yml supabase-deploy-prod.yml; do
  stamp_file "$ROOT/templates/github-workflows/$f" "$tmp/$f"
  assert_eq "$?" "0" "$f stamps clean"
done
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "SUPABASE_DB_URL_STAGING" "dev workflow uses staging db url secret"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "SUPABASE_DB_URL_PROD" "prod workflow uses prod db url secret"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "branches: [dev]" "supabase dev workflow triggers on dev"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "branches: [main]" "supabase prod workflow triggers on main"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "environment: staging" "supabase dev workflow declares staging environment"
assert_contains "$(cat "$tmp/supabase-deploy-prod.yml")" "environment: production" "supabase prod workflow declares production environment"
assert_contains "$(cat "$tmp/supabase-deploy-dev.yml")" "db push" "dev workflow pushes migrations"

rm -rf "$tmp"
exit "$FAILS"
