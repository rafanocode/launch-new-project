#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

stub_supabase_happy() {
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme Org\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"refabc123\",\"name\":\"$3\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_xyz\"},{\"name\":\"default\",\"type\":\"secret\",\"api_key\":\"sb_secret_xyz\"}]"; exit 0;;
  *) exit 0;;
esac'
}

# Happy path: single org auto-resolved, two projects created, keys extracted
stub_supabase_happy
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds when org is unambiguous and projects are new"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=refabc123" "writes prod ref"
assert_contains "$k" "SUPABASE_URL_PROD=https://refabc123.supabase.co" "writes prod url"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_PROD=sb_publishable_xyz" "writes prod publishable key"
assert_contains "$k" "SUPABASE_DB_URL_PROD=postgresql://postgres:" "writes prod db url"
assert_contains "$k" "SUPABASE_REF_STAGING=refabc123" "writes staging ref"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_STAGING=sb_publishable_xyz" "writes staging publishable key"
case "$out" in *sb_secret_xyz*) echo "  FAIL: secret key leaked to stdout"; FAILS=$((FAILS+1));; *) echo "  ok: no secret key on stdout";; esac
rm -f "$keys"

# Multiple orgs, no --org-id given -> fatal, lists them
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"},{\"id\":\"org2\",\"name\":\"Other\",\"slug\":\"org2\"}]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when multiple orgs and no --org-id"
assert_contains "$out" "org1" "lists org1 as a candidate"
assert_contains "$out" "org2" "lists org2 as a candidate"
rm -f "$keys"

# --org-id explicit skips org resolution entirely
stub_supabase_happy
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" --org-id org2)"; rc=$?
assert_eq "$rc" "0" "succeeds with explicit --org-id"
rm -f "$keys"

# Project already exists (by name) -> fatal, password unrecoverable, no silent reuse
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[{\"name\":\"acme-prod\",\"ref\":\"existingref\"}]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when the target project already exists (password unrecoverable)"
assert_contains "$out" "acme-prod" "names the conflicting project"
rm -f "$keys"

# projects create real failure -> fatal (not swallowed)
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "quota exceeded" >&2; exit 1;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when projects create genuinely fails"
rm -f "$keys"

exit "$FAILS"
