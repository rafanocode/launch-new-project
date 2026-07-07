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
rm -rf "$tmp"
exit "$FAILS"
