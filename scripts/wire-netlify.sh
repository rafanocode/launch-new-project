#!/usr/bin/env bash
set -u
# Creates a Netlify site and sets CONVEX_DEPLOY_KEY + NEXT_PUBLIC_CONVEX_URL
# per Netlify deploy context: production gets the prod values, deploy-preview
# and branch-deploy get the staging values.
#
# Reads PROD_KEY / STAGING_KEY from --keys-file (written earlier by
# setup-convex.sh). Does not delete the keys file; orchestration does that.
#
# KNOWN LIMITATION: unlike `vercel env add` / `gh secret set`, which read the
# secret value from stdin, the Netlify CLI's `env:set` takes the value as a
# positional argument. There is no stdin option, so the Convex deploy key
# transits the process argv here (visible in `ps`/shell history) instead of
# being piped in. This is a Netlify CLI limitation, not a choice made here.
SITE="${1:?usage: wire-netlify.sh <site> <keys-file> --prod-url U --staging-url U}"; shift
KEYS_FILE="${1:?keys file required}"; shift
PROD_URL=""; STAGING_URL=""
while [ $# -gt 0 ]; do case "$1" in
  --prod-url) PROD_URL="$2"; shift 2;;
  --staging-url) STAGING_URL="$2"; shift 2;;
  *) shift;; esac; done
# shellcheck disable=SC1090
. "$KEYS_FILE"

netlify sites:create --name "$SITE" >/dev/null 2>&1 || echo "netlify: site exists (continuing)"

set_ctx() { # <name> <context> <value>
  netlify env:set "$1" "$3" --context "$2" >/dev/null 2>&1 \
    && echo "netlify: set $1 [$2]" || echo "netlify: $1 [$2] failed (continuing)"
}
set_ctx CONVEX_DEPLOY_KEY production     "${PROD_KEY:-}"
set_ctx CONVEX_DEPLOY_KEY deploy-preview "${STAGING_KEY:-}"
set_ctx CONVEX_DEPLOY_KEY branch-deploy  "${STAGING_KEY:-}"
set_ctx NEXT_PUBLIC_CONVEX_URL production     "$PROD_URL"
set_ctx NEXT_PUBLIC_CONVEX_URL deploy-preview "$STAGING_URL"
set_ctx NEXT_PUBLIC_CONVEX_URL branch-deploy  "$STAGING_URL"
echo "netlify: env configured for $SITE"
