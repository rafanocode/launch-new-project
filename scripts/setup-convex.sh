#!/usr/bin/env bash
set -u
# Creates (or reuses) a Convex project, ensures a "staging" prod-type
# deployment exists alongside the project's default production deployment,
# and mints deploy keys for both. Keys are written only to --keys-file
# (umask 077), never to stdout — later setup steps (GitHub secrets, etc.)
# consume that file.
#
# --team / CONVEX_TEAM: `convex project create` defaults to the account's
# only team, or PROMPTS when there are several (verified via
# `npx convex project create --help`; there is no CLI subcommand to list
# teams, unlike Supabase's `orgs list`). Passing --team explicitly avoids
# that interactive prompt ever happening in a non-interactive run; stdin is
# also redirected from /dev/null so an unexpected prompt fails fast instead
# of hanging.
#
# Note: real end-to-end provisioning (e.g. that a freshly created project
# actually has a default "prod" deployment available for token minting) is
# validated by the E2E checklist, not by these unit tests — the tests here
# stub the `convex` CLI so no real Convex account is touched.
SLUG="${1:?usage: setup-convex.sh <slug> --keys-file <path> [--team <team_slug>]}"; shift
KEYS_FILE=""
TEAM="${CONVEX_TEAM:-}"
while [ $# -gt 0 ]; do case "$1" in
  --keys-file) KEYS_FILE="$2"; shift 2;;
  --team) TEAM="$2"; shift 2;;
  *) shift;;
esac; done
[ -n "$KEYS_FILE" ] || { echo "setup-convex: --keys-file required" >&2; exit 2; }

team_flag=()
[ -n "$TEAM" ] && team_flag=(--team "$TEAM")

# 1. Project (idempotent: a non-zero "already exists" is not fatal)
echo "convex: ensuring project $SLUG"
# "${team_flag[@]+"${team_flag[@]}"}" (not a bare "${team_flag[@]}") — expanding a
# declared-but-empty array under `set -u` is an unbound-variable error on bash
# <4.4 (confirmed on this repo's target, macOS's bash 3.2); the ${arr[@]+word}
# form only substitutes when the array actually has elements.
convex project create "$SLUG" "${team_flag[@]+"${team_flag[@]}"}" </dev/null >/dev/null 2>&1 \
  || echo "convex: project exists or already created, continuing"

# 2. Staging prod-type deployment (idempotent)
echo "convex: ensuring staging deployment"
convex deployment create staging --type prod </dev/null >/dev/null 2>&1 || echo "convex: staging exists, continuing"

# 3. Deploy keys — captured, never printed
echo "convex: minting deploy keys"
prod_key="$(convex deployment token create ci-prod --deployment prod 2>/dev/null | tail -n1)"
staging_key="$(convex deployment token create ci-staging --deployment staging 2>/dev/null | tail -n1)"
[ -n "$prod_key" ] && [ -n "$staging_key" ] || { echo "convex: failed to mint deploy keys" >&2; exit 1; }

umask 077
{ echo "PROD_KEY=$prod_key"; echo "STAGING_KEY=$staging_key"; } > "$KEYS_FILE"
echo "convex: setup complete (keys written to keys file)"
