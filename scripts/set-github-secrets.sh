#!/usr/bin/env bash
set -u
REPO="${1:?usage: set-github-secrets.sh <owner/repo> <keys-file> [backend]}"
KEYS_FILE="${2:?keys file required}"
BACKEND="${3:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"   # defines PROD_KEY/STAGING_KEY (convex) or SUPABASE_DB_URL_* (supabase)

set_secret() { # <name> <value> — value via stdin, never argv
  if printf '%s' "$2" | gh secret set "$1" --repo "$REPO" >/dev/null 2>&1; then
    echo "gh: set secret $1"
  else
    echo "gh: failed to set $1" >&2
    return 1
  fi
}

case "$BACKEND" in
  convex)
    set_secret CONVEX_DEPLOY_KEY_PROD "${PROD_KEY:-}" || exit 1
    set_secret CONVEX_DEPLOY_KEY_STAGING "${STAGING_KEY:-}" || exit 1
    ;;
  supabase)
    set_secret SUPABASE_DB_URL_PROD "${SUPABASE_DB_URL_PROD:-}" || exit 1
    if [ "${SUPABASE_STAGING_PROVISIONED:-yes}" = "no" ]; then
      echo "gh: staging not provisioned (best-effort branch creation didn't complete) — skipping SUPABASE_DB_URL_STAGING"
    else
      set_secret SUPABASE_DB_URL_STAGING "${SUPABASE_DB_URL_STAGING:-}" || exit 1
    fi
    ;;
  *)
    echo "gh: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac

for envname in staging production; do
  gh api -X PUT "repos/$REPO/environments/$envname" >/dev/null 2>&1 \
    && echo "gh: ensured environment $envname" || echo "gh: environment $envname not created (continuing)"
done

# NOTE: do not delete the keys file here — the deploy-host step still needs the
# values. The orchestration deletes it at the end of Phase 2.
echo "gh: secrets and environments configured"
