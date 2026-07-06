#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
f="$ROOT/command/init-2env.md"
c="$(cat "$f")"
assert_contains "$c" "description:" "has frontmatter description"
assert_contains "$c" "allowed-tools:" "declares allowed-tools"
for s in preflight setup-convex create-github-repo set-github-secrets wire-vercel wire-netlify; do
  assert_contains "$c" "$s" "references $s script"
done
assert_contains "$c" "Execute all" "has the single confirmation gate"
assert_contains "$c" "list_teams" "creates/looks up Linear team"
case "$c" in *"{{"*) echo "  FAIL: command contains unstamped {{ markers"; FAILS=$((FAILS+1));; *) echo "  ok: no stray markers";; esac
exit "$FAILS"
