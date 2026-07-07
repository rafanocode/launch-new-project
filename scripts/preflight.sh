#!/usr/bin/env bash
set -u
DEPLOY="vercel"
BACKEND="convex"
while [ $# -gt 0 ]; do case "$1" in
  --deploy) DEPLOY="$2"; shift 2;;
  --backend) BACKEND="$2"; shift 2;;
  *) shift;;
esac; done

fatal=0
check() { # <name> <hint> ; runs following command via "$@" after first two args
  local name="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "OK $name"; else echo "MISSING $name: $hint"; fatal=1; fi
}

check gh "run: gh auth login" gh auth status
check jq "run: brew install jq (or your package manager's jq)" jq --version

# shellcheck disable=SC2329
convex_present() { command -v convex >/dev/null 2>&1 || npx --no-install convex --version >/dev/null 2>&1; }
check convex "run: npm i -g convex (or ensure npx convex works)" convex_present

if [ "$DEPLOY" = "netlify" ]; then
  # shellcheck disable=SC2329
  netlify_authed() {
    command -v netlify >/dev/null 2>&1 || return 1
    netlify status >/dev/null 2>&1
  }
  check netlify "set NETLIFY_AUTH_TOKEN or run: npm i -g netlify-cli && netlify login" netlify_authed
else
  # shellcheck disable=SC2329
  vercel_authed() {
    command -v vercel >/dev/null 2>&1 || return 1
    vercel whoami >/dev/null 2>&1
  }
  check vercel "set VERCEL_TOKEN or run: vercel login" vercel_authed
fi

if [ "$BACKEND" = "supabase" ]; then
  # shellcheck disable=SC2329
  supabase_authed() {
    command -v supabase >/dev/null 2>&1 || return 1
    supabase projects list >/dev/null 2>&1
  }
  check supabase "set SUPABASE_ACCESS_TOKEN or run: npm i -g supabase && supabase login" supabase_authed
fi

# Linear is required: the command creates the team/project via the Linear GraphQL API.
if [ -n "${LINEAR_API_KEY:-}" ]; then echo "OK linear (LINEAR_API_KEY)"; else echo "MISSING linear: export LINEAR_API_KEY (needed to create the Linear team/project)"; fatal=1; fi

exit "$fatal"
