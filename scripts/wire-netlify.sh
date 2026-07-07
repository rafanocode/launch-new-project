#!/usr/bin/env bash
set -u
# Creates a Netlify site (idempotent via `sites:list`, not exit-code
# guessing) and sets the backend's env vars per Netlify deploy context.
# Auth is via NETLIFY_AUTH_TOKEN (verified in Netlify's own CI docs,
# analogous to Vercel's VERCEL_TOKEN) or a prior `netlify login` session.
# `env:set` always overwrites (there is no "already exists" case for it),
# so any non-zero exit from it is a real failure and propagates.
#
# Reads the backend's keys from the keys file (written earlier by
# setup-convex.sh / setup-supabase.sh). Does not delete the keys file;
# orchestration does that.
#
# KNOWN LIMITATION: unlike `vercel env add` / `gh secret set`, which read the
# secret value from stdin, the Netlify CLI's `env:set` takes the value as a
# positional argument. There is no stdin option, so the deploy key transits
# the process argv here (visible in `ps`/shell history) instead of being
# piped in. This is a Netlify CLI limitation, not a choice made here.
SITE="${1:?usage: wire-netlify.sh <site> <keys-file> [backend]}"; shift
KEYS_FILE="${1:?keys file required}"; shift
BACKEND="${1:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"

existing="$(netlify sites:list --json 2>/dev/null | jq -r --arg n "$SITE" '.[] | select(.name == $n) | .site_id' | head -n1)"
if [ -n "$existing" ]; then
  echo "netlify: site $SITE exists ($existing), reusing"
else
  netlify sites:create --name "$SITE" >/dev/null 2>&1 \
    || { echo "netlify: failed to create site $SITE" >&2; exit 1; }
  echo "netlify: site $SITE created"
fi

set_ctx() { # <name> <context> <value>
  netlify env:set "$1" "$3" --context "$2" --force >/dev/null 2>&1 || {
    echo "netlify: failed to set $1 [$2]" >&2
    return 1
  }
  echo "netlify: set $1 [$2]"
}

case "$BACKEND" in
  convex)
    set_ctx CONVEX_DEPLOY_KEY production     "${PROD_KEY:-}"    || exit 1
    set_ctx CONVEX_DEPLOY_KEY deploy-preview "${STAGING_KEY:-}" || exit 1
    set_ctx CONVEX_DEPLOY_KEY branch-deploy  "${STAGING_KEY:-}" || exit 1
    ;;
  supabase)
    echo "netlify: unknown backend 'supabase' handling not yet implemented" >&2
    exit 1
    ;;
  *)
    echo "netlify: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac
echo "netlify: env configured for $SITE"
echo "NOTE: the netlify.toml [build] command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL. The orchestration writes this into netlify.toml; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var."
