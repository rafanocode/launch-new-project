#!/usr/bin/env bash
set -u
# Creates a Netlify site and sets CONVEX_DEPLOY_KEY per Netlify deploy context:
# production gets the prod key, deploy-preview and branch-deploy get the staging
# key. The key selects WHICH Convex deployment; NEXT_PUBLIC_CONVEX_URL is
# injected at build time by the build command (see NOTE below), never stored.
#
# Reads PROD_KEY / STAGING_KEY from the keys file (written earlier by
# setup-convex.sh). Does not delete the keys file; orchestration does that.
#
# KNOWN LIMITATION: unlike `vercel env add` / `gh secret set`, which read the
# secret value from stdin, the Netlify CLI's `env:set` takes the value as a
# positional argument. There is no stdin option, so the Convex deploy key
# transits the process argv here (visible in `ps`/shell history) instead of
# being piped in. This is a Netlify CLI limitation, not a choice made here.
SITE="${1:?usage: wire-netlify.sh <site> <keys-file>}"; shift
KEYS_FILE="${1:?keys file required}"; shift
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
echo "netlify: env configured for $SITE"
echo "NOTE: the netlify.toml [build] command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL. The orchestration writes this into netlify.toml; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var."
