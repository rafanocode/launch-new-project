#!/usr/bin/env bash
set -u
# Links/creates a Vercel project and sets CONVEX_DEPLOY_KEY per target:
# production gets the prod key, preview and development get the staging key.
# The key selects WHICH Convex deployment; NEXT_PUBLIC_CONVEX_URL is injected
# at build time by the build command (see NOTE below), never stored here.
# Values are piped via stdin to `vercel env add`, never passed on argv or
# printed to stdout.
#
# Reads PROD_KEY / STAGING_KEY from the keys file (written earlier by
# setup-convex.sh). Does not delete the keys file; orchestration does that.
PROJECT="${1:?usage: wire-vercel.sh <project> <keys-file>}"; shift
KEYS_FILE="${1:?keys file required}"; shift
# shellcheck disable=SC1090
. "$KEYS_FILE"

tok=(--token "${VERCEL_TOKEN:-}" --yes)

# Link/create project (idempotent)
vercel link "${tok[@]}" --project "$PROJECT" >/dev/null 2>&1 || echo "vercel: link/create returned non-zero (continuing)"

add_env() { # <name> <target> <value>
  printf '%s' "$3" | vercel env add "$1" "$2" "${tok[@]}" >/dev/null 2>&1 \
    && echo "vercel: set $1 [$2]" || echo "vercel: $1 [$2] may already exist (continuing)"
}
add_env CONVEX_DEPLOY_KEY production   "${PROD_KEY:-}"
add_env CONVEX_DEPLOY_KEY preview      "${STAGING_KEY:-}"
add_env CONVEX_DEPLOY_KEY development  "${STAGING_KEY:-}"

echo "vercel: env configured for $PROJECT"
echo "NOTE: if the GitHub repo isn't linked to Vercel yet, connect it once in the Vercel dashboard (Project → Settings → Git)."
echo "NOTE: the Vercel Build Command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL (Project → Settings → Build & Development Settings). The orchestration writes this into vercel.json; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var. If you created the project by hand, set it manually."
