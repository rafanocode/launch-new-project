#!/usr/bin/env bash
set -u
# Links/creates a Vercel project and sets the backend's env vars per target.
# Auth is via the VERCEL_TOKEN env var only (never passed as --token on argv,
# which would leak in `ps`/process listings — see the Vercel CLI's own CI
# guidance). Values are piped via stdin to `vercel env add`, never passed on
# argv or printed to stdout. `--force` makes re-adding an existing var
# succeed instead of prompting, so every remaining non-zero exit here is a
# real failure (auth, network, invalid project) and must propagate.
#
# Reads the backend's keys from the keys file (written earlier by
# setup-convex.sh / setup-supabase.sh). Does not delete the keys file;
# orchestration does that.
PROJECT="${1:?usage: wire-vercel.sh <project> <keys-file> [backend]}"; shift
KEYS_FILE="${1:?keys file required}"; shift
BACKEND="${1:-convex}"
# shellcheck disable=SC1090
. "$KEYS_FILE"

vercel link --project "$PROJECT" --yes >/dev/null 2>&1 \
  || { echo "vercel: link/create failed for $PROJECT" >&2; exit 1; }

add_env() { # <name> <target> <value>
  printf '%s' "$3" | vercel env add "$1" "$2" --force --yes >/dev/null 2>&1 || {
    echo "vercel: failed to set $1 [$2]" >&2
    return 1
  }
  echo "vercel: set $1 [$2]"
}

case "$BACKEND" in
  convex)
    add_env CONVEX_DEPLOY_KEY production   "${PROD_KEY:-}"    || exit 1
    add_env CONVEX_DEPLOY_KEY preview      "${STAGING_KEY:-}" || exit 1
    add_env CONVEX_DEPLOY_KEY development  "${STAGING_KEY:-}" || exit 1
    echo "NOTE: the Vercel Build Command must be: npx convex deploy --cmd 'npm run build' --cmd-url-env-var-name NEXT_PUBLIC_CONVEX_URL (Project → Settings → Build & Development Settings). The orchestration writes this into vercel.json; NEXT_PUBLIC_CONVEX_URL is injected at build time, not stored as an env var. If you created the project by hand, set it manually."
    ;;
  supabase)
    add_env NEXT_PUBLIC_SUPABASE_URL            production "${SUPABASE_URL_PROD:-}"            || exit 1
    add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY production "${SUPABASE_PUBLISHABLE_KEY_PROD:-}" || exit 1
    if [ "${SUPABASE_STAGING_PROVISIONED:-yes}" = "no" ]; then
      echo "vercel: staging not provisioned (best-effort Supabase branch creation didn't complete) — skipping preview/development env vars"
    else
      add_env NEXT_PUBLIC_SUPABASE_URL            preview    "${SUPABASE_URL_STAGING:-}"            || exit 1
      add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY preview    "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
      add_env NEXT_PUBLIC_SUPABASE_URL            development "${SUPABASE_URL_STAGING:-}"            || exit 1
      add_env NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY development "${SUPABASE_PUBLISHABLE_KEY_STAGING:-}" || exit 1
    fi
    ;;
  *)
    echo "vercel: unknown backend '$BACKEND'" >&2
    exit 1
    ;;
esac

echo "vercel: env configured for $PROJECT"
echo "NOTE: if the GitHub repo isn't linked to Vercel yet, connect it once in the Vercel dashboard (Project → Settings → Git)."
