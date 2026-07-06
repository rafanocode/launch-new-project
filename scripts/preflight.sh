#!/usr/bin/env bash
set -u
DEPLOY="vercel"
while [ $# -gt 0 ]; do case "$1" in --deploy) DEPLOY="$2"; shift 2;; *) shift;; esac; done

fatal=0
check() { # <name> <hint> ; runs following command via "$@" after first two args
  local name="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo "OK $name"; else echo "MISSING $name: $hint"; fatal=1; fi
}

check gh "run: gh auth login" gh auth status
check convex "run: npm i -g convex (or npx convex)" command -v convex
if [ "$DEPLOY" = "netlify" ]; then
  check netlify "run: npm i -g netlify-cli && netlify login" command -v netlify
else
  check vercel "set VERCEL_TOKEN or run: vercel login" command -v vercel
fi

# Linear is required: the command creates the team/project via the Linear GraphQL API.
if [ -n "${LINEAR_API_KEY:-}" ]; then echo "OK linear (LINEAR_API_KEY)"; else echo "MISSING linear: export LINEAR_API_KEY (needed to create the Linear team/project)"; fatal=1; fi

exit "$fatal"
