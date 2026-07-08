#!/usr/bin/env bash
set -u
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/with_stubs.sh"

# resolve_pooler_host() retries for up to 5 minutes (30 x 10s) against a
# newly-provisioning real project -- override both to keep this suite fast.
SUPABASE_POOLER_RETRY_ATTEMPTS=2
SUPABASE_POOLER_RETRY_INTERVAL=0
export SUPABASE_POOLER_RETRY_ATTEMPTS SUPABASE_POOLER_RETRY_INTERVAL

stub_supabase_happy() {
make_stub supabase '
echo "supabase $*" >> "${SUPABASE_CALL_LOG:-/dev/null}"
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme Org\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"refabc123\",\"name\":\"$3\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_xyz\"},{\"name\":\"default\",\"type\":\"secret\",\"api_key\":\"sb_secret_xyz\"}]"; exit 0;;
  "link --project-ref") mkdir -p supabase/.temp; echo "postgresql://postgres.$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres" > supabase/.temp/pooler-url; exit 0;;
  *) exit 0;;
esac'
}

# Happy path: single org auto-resolved, two projects created, keys extracted
SUPABASE_CALL_LOG="$(mktemp)"; export SUPABASE_CALL_LOG
stub_supabase_happy
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "succeeds when org is unambiguous and projects are new"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=refabc123" "writes prod ref"
assert_contains "$k" "SUPABASE_URL_PROD=https://refabc123.supabase.co" "writes prod url"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_PROD=sb_publishable_xyz" "writes prod publishable key"
assert_contains "$k" "SUPABASE_DB_URL_PROD=postgresql://postgres.refabc123:" "writes prod db url with the per-project pooler username"
assert_contains "$k" "aws-0-us-east-1.pooler.supabase.com:6543" "uses the IPv4 pooler host/transaction-mode port, not the IPv6-only direct connection"
assert_not_contains "$k" "db.refabc123.supabase.co" "does not use the direct (IPv6-only) connection host"
assert_contains "$k" "SUPABASE_REF_STAGING=refabc123" "writes staging ref"
assert_contains "$k" "SUPABASE_PUBLISHABLE_KEY_STAGING=sb_publishable_xyz" "writes staging publishable key"
case "$out" in *sb_secret_xyz*) echo "  FAIL: secret key leaked to stdout"; FAILS=$((FAILS+1));; *) echo "  ok: no secret key on stdout";; esac
prod_pw="$(printf '%s' "$k" | sed -n 's#^SUPABASE_DB_URL_PROD=postgresql://postgres\.refabc123:\([^@]*\)@.*#\1#p')"
assert_not_contains "$out" "$prod_pw" "generated db password never appears on stdout"
assert_contains "$(cat "$SUPABASE_CALL_LOG")" "--region" "passes --region to projects create"
rm -f "$keys" "$SUPABASE_CALL_LOG"
unset SUPABASE_CALL_LOG

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

# Zero orgs, no --org-id given -> fatal, distinct message from the multi-org case
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[]"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when zero orgs and no --org-id"
assert_contains "$out" "no organizations found" "reports zero orgs distinctly from the multi-org case"
assert_not_contains "$out" "multiple organizations" "does not misreport zero orgs as multiple"
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

# projects create succeeds but the real CLI writes noise to stderr (version
# update banner) alongside clean JSON on stdout -- must not be treated as a
# parse failure just because stderr is non-empty (regression: a real E2E run
# hit this exact case and orphaned a real cloud project because the old code
# merged 2>&1, corrupting the JSON jq needed to parse)
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "A new version of Supabase CLI is available" >&2; echo "{\"ref\":\"noisyref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_noisy\"}]"; exit 0;;
  "link --project-ref") mkdir -p supabase/.temp; echo "postgresql://postgres.$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres" > supabase/.temp/pooler-url; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_eq "$rc" "0" "succeeds even when the CLI writes a version-update banner to stderr on create"
assert_contains "$(cat "$keys")" "SUPABASE_REF_PROD=noisyref1" "still extracts the ref despite stderr noise on the create call"
rm -f "$keys"

# project still provisioning on the first attempt (real behavior: freshly
# created projects stay COMING_UP for a while before the pooler is ready)
# -> resolve_pooler_host retries and succeeds once link works
link_attempts="$(mktemp)"; printf '0' > "$link_attempts"
make_stub supabase "
case \"\$1 \$2\" in
  \"orgs list\") echo '[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]'; exit 0;;
  \"projects list\") echo '[]'; exit 0;;
  \"projects create\") echo '{\"ref\":\"refslow\"}'; exit 0;;
  \"projects api-keys\") echo '[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_xyz\"}]'; exit 0;;
  \"link --project-ref\")
    n=\$(cat '$link_attempts'); n=\$((n+1)); printf '%s' \"\$n\" > '$link_attempts'
    if [ \"\$n\" -lt 2 ]; then exit 1; fi
    mkdir -p supabase/.temp; echo 'postgresql://postgres.\$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres' > supabase/.temp/pooler-url; exit 0;;
  *) exit 0;;
esac"
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_eq "$rc" "0" "succeeds once the pooler becomes ready on a later retry"
assert_contains "$(cat "$keys")" "SUPABASE_DB_URL_PROD=postgresql://postgres.refslow:" "still writes the pooler-based db url after retrying"
assert_contains "$out" "still provisioning" "explains the wait to the user"
rm -f "$keys" "$link_attempts"

# pooler host cannot be resolved (e.g. `supabase link` fails or is too old
# to write .temp/pooler-url) -> fatal, not a silent fallback to the
# IPv6-only direct connection (which would just fail later, in CI, far from
# this script's own clear error message)
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"refnopool\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_xyz\"}]"; exit 0;;
  "link --project-ref") exit 1;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode projects --keys-file "$keys" 2>&1)"; rc=$?
assert_fail_exit "$rc" "fatal when the IPv4 pooler host can't be resolved"
assert_contains "$out" "could not resolve the IPv4 pooler host" "explains why it failed"
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

# mode=branch, branch creation succeeds
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"prodref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_prod\"}]"; exit 0;;
  "link --project-ref") mkdir -p supabase/.temp; echo "postgresql://postgres.$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres" > supabase/.temp/pooler-url; exit 0;;
  "branches create") echo "{\"ref\":\"branchref1\"}"; exit 0;;
  "branches get") echo "{\"ref\":\"branchref1\"}"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "mode=branch succeeds when branch creation works"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=prodref1" "writes prod ref"
assert_contains "$k" "SUPABASE_STAGING_PROVISIONED=yes" "marks staging as provisioned"
assert_contains "$k" "SUPABASE_REF_STAGING=branchref1" "writes staging ref from the branch"
rm -f "$keys"

# mode=branch, branch creation succeeds but the real CLI writes noise to
# stderr alongside clean JSON on stdout -- must not be misclassified as a
# best-effort failure just because stderr is non-empty (same regression
# class as the projects-create case above, for the branches create call)
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"prodref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_prod\"}]"; exit 0;;
  "link --project-ref") mkdir -p supabase/.temp; echo "postgresql://postgres.$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres" > supabase/.temp/pooler-url; exit 0;;
  "branches create") echo "A new version of Supabase CLI is available" >&2; echo "{\"ref\":\"branchref1\"}"; exit 0;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "mode=branch succeeds when the CLI writes stderr noise on a successful branch create"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_STAGING_PROVISIONED=yes" "does not misclassify a noisy-but-successful branch create as failed"
assert_contains "$k" "SUPABASE_REF_STAGING=branchref1" "still extracts the branch ref despite stderr noise"
rm -f "$keys"

# mode=branch, branch creation fails -> non-fatal, staging marked not-provisioned
make_stub supabase '
case "$1 $2" in
  "orgs list") echo "[{\"id\":\"org1\",\"name\":\"Acme\",\"slug\":\"org1\"}]"; exit 0;;
  "projects list") echo "[]"; exit 0;;
  "projects create") echo "{\"ref\":\"prodref1\"}"; exit 0;;
  "projects api-keys") echo "[{\"name\":\"default\",\"type\":\"publishable\",\"api_key\":\"sb_publishable_prod\"}]"; exit 0;;
  "link --project-ref") mkdir -p supabase/.temp; echo "postgresql://postgres.$3@aws-0-us-east-1.pooler.supabase.com:5432/postgres" > supabase/.temp/pooler-url; exit 0;;
  "branches create") echo "GitHub integration not connected" >&2; exit 1;;
  *) exit 0;;
esac'
keys="$(mktemp)"
out="$(bash "$ROOT/scripts/setup-supabase.sh" acme --mode branch --keys-file "$keys")"; rc=$?
assert_eq "$rc" "0" "mode=branch still exits 0 when branch creation fails (non-fatal, best-effort)"
k="$(cat "$keys")"
assert_contains "$k" "SUPABASE_REF_PROD=prodref1" "still writes prod ref"
assert_contains "$k" "SUPABASE_STAGING_PROVISIONED=no" "marks staging as not provisioned"
assert_not_contains "$k" "SUPABASE_REF_STAGING" "does not write a staging ref when the branch failed"
assert_contains "$out" "connect this repo in Supabase" "prints the manual follow-up instruction"
rm -f "$keys"

exit "$FAILS"
