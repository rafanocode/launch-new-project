#!/usr/bin/env bash
set -u
REPO="${1:?usage: set-github-secrets.sh <owner/repo> <keys-file>}"
KEYS_FILE="${2:?keys file required}"
# shellcheck disable=SC1090
. "$KEYS_FILE"   # defines PROD_KEY, STAGING_KEY

set_secret() { # <name> <value> — value via stdin, never argv
  if printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null 2>&1; then
    echo "gh: set secret $1"
  else
    echo "gh: failed to set $1" >&2
    return 1
  fi
}
set_secret CONVEX_DEPLOY_KEY_PROD "${PROD_KEY:-}" || exit 1
set_secret CONVEX_DEPLOY_KEY_STAGING "${STAGING_KEY:-}" || exit 1

for envname in staging production; do
  gh api -X PUT "repos/$REPO/environments/$envname" >/dev/null 2>&1 \
    && echo "gh: ensured environment $envname" || echo "gh: environment $envname not created (continuing)"
done

# NOTE: do not delete the keys file here — the deploy-host step still needs the
# values. The orchestration (Task 13) deletes it at the end of Phase 2.
echo "gh: secrets and environments configured"
