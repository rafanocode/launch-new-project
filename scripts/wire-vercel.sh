#!/usr/bin/env bash
set -u
# Links/creates a Vercel project and sets CONVEX_DEPLOY_KEY +
# NEXT_PUBLIC_CONVEX_URL per target: production gets the prod values,
# preview and development get the staging values. Values are piped via
# stdin to `vercel env add`, never passed on argv or printed to stdout.
#
# Reads PROD_KEY / STAGING_KEY from --keys-file (written earlier by
# setup-convex.sh). Does not delete the keys file; orchestration does that.
PROJECT="${1:?usage: wire-vercel.sh <project> <keys-file> --prod-url U --staging-url U}"; shift
KEYS_FILE="${1:?keys file required}"; shift
PROD_URL=""; STAGING_URL=""
while [ $# -gt 0 ]; do case "$1" in
  --prod-url) PROD_URL="$2"; shift 2;;
  --staging-url) STAGING_URL="$2"; shift 2;;
  *) shift;; esac; done
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
add_env NEXT_PUBLIC_CONVEX_URL production   "$PROD_URL"
add_env NEXT_PUBLIC_CONVEX_URL preview      "$STAGING_URL"
add_env NEXT_PUBLIC_CONVEX_URL development  "$STAGING_URL"

echo "vercel: env configured for $PROJECT"
echo "NOTE: if the GitHub repo isn't linked to Vercel yet, connect it once in the Vercel dashboard (Project → Settings → Git)."
echo "NOTE: set the Vercel Build Command to: npx convex deploy --cmd 'npm run build' (Project → Settings → Build & Development Settings). The orchestration stamps this into vercel.json when it scaffolds; if you created the project by hand, set it manually."
