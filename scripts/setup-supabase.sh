#!/usr/bin/env bash
set -u
# Creates (or, for mode=branch, extends) a Supabase backend for the
# two-environment model. Two modes:
#   --mode projects  Two separate Supabase projects (<slug>-prod,
#                     <slug>-staging), each with its own DB password,
#                     migrated independently via CI (see
#                     templates/github-workflows/supabase-deploy-*.yml).
#   --mode branch     One project (<slug>, production) plus a best-effort
#                      persistent branch named "dev" for staging. See the
#                      --mode branch block (Task 7) for its non-fatal
#                      failure handling.
#
# Keys/URLs/connection strings are written only to --keys-file (umask 077),
# never to stdout — later steps (deploy-host wiring) consume that file.
#
# DB passwords are only ever knowable at project-creation time (the
# Supabase CLI has no password-reset/reveal command). If a project with the
# target name already exists, this script cannot safely resume it and
# stops rather than guessing — re-run from scratch after deleting the
# leftover project (see command/init-2env.md's cleanup-on-failure step).
SLUG="${1:?usage: setup-supabase.sh <slug> --mode projects|branch --keys-file <path> [--org-id <id>]}"; shift
MODE=""
ORG_ID="${SUPABASE_ORG_ID:-}"
KEYS_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --org-id) ORG_ID="$2"; shift 2;;
  --keys-file) KEYS_FILE="$2"; shift 2;;
  *) shift;;
esac; done
case "$MODE" in projects|branch) ;; *) echo "setup-supabase: --mode projects|branch required" >&2; exit 2;; esac
[ -n "$KEYS_FILE" ] || { echo "setup-supabase: --keys-file required" >&2; exit 2; }

# --- org resolution -----------------------------------------------------
if [ -z "$ORG_ID" ]; then
  orgs_json="$(supabase orgs list -o json 2>/dev/null)" || { echo "setup-supabase: failed to list organizations" >&2; exit 1; }
  count="$(printf '%s' "$orgs_json" | jq 'length')"
  case "$count" in
    1) ORG_ID="$(printf '%s' "$orgs_json" | jq -r '.[0].id')" ;;
    0)
      echo "setup-supabase: no organizations found on this account — create one first (https://supabase.com/dashboard/org/new or 'supabase orgs create'), then re-run." >&2
      exit 1
      ;;
    *)
      echo "setup-supabase: multiple organizations found, pass --org-id (or export SUPABASE_ORG_ID):" >&2
      printf '%s' "$orgs_json" | jq -r '.[] | "  \(.id)  \(.name)"' >&2
      exit 1
      ;;
  esac
fi

# --- helpers --------------------------------------------------------------
gen_db_password() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

find_project_ref() { # <name>
  supabase projects list -o json 2>/dev/null | jq -r --arg n "$1" '.[] | select(.name == $n) | .ref' | head -n1
}

# Creates a NEW project named <name>; fails loudly (does not reuse) if one
# already exists, since its DB password is unrecoverable. On success prints
# "<ref> <password>" (space-separated) to stdout.
create_project() { # <name>
  local name="$1" existing ref pw out region
  region="${SUPABASE_REGION:-us-east-1}"
  existing="$(find_project_ref "$name")"
  if [ -n "$existing" ]; then
    echo "setup-supabase: project '$name' already exists ($existing) but its DB password can only be captured at creation time — cannot safely resume." >&2
    echo "setup-supabase: delete '$name' (or the whole partial run) in the Supabase dashboard and re-run setup-supabase.sh from scratch." >&2
    return 1
  fi
  pw="$(gen_db_password)"
  out="$(supabase projects create "$name" --org-id "$ORG_ID" --db-password "$pw" --region "$region" -o json 2>&1)" \
    || { echo "setup-supabase: failed to create project '$name': $out" >&2; return 1; }
  ref="$(printf '%s' "$out" | jq -r '.ref // .id // empty' 2>/dev/null)"
  [ -n "$ref" ] || { echo "setup-supabase: could not determine project ref for '$name' from: $out" >&2; return 1; }
  printf '%s %s' "$ref" "$pw"
}

# Extracts the client-safe key (publishable, falling back to legacy anon)
# for a project ref. Fails loudly on an empty/null result rather than
# writing a broken env var — the installed CLI has no --reveal flag to
# un-redact a masked key, so a null here means something is genuinely wrong.
extract_public_key() { # <ref>
  local keys_json key
  keys_json="$(supabase projects api-keys --project-ref "$1" -o json 2>/dev/null)" || return 1
  key="$(printf '%s' "$keys_json" | jq -r '
    ([.[] | select(.type == "publishable")] | .[0].api_key) //
    ([.[] | select(.name == "anon")] | .[0].api_key) //
    empty')"
  [ -n "$key" ] && [ "$key" != "null" ] || return 1
  printf '%s' "$key"
}

write_env_block() { # <suffix PROD|STAGING> <ref> <password>
  local suffix="$1" ref="$2" pw="$3" pub
  pub="$(extract_public_key "$ref")" || { echo "setup-supabase: failed to extract a usable publishable/anon key for $ref" >&2; return 1; }
  {
    echo "SUPABASE_REF_${suffix}=${ref}"
    echo "SUPABASE_URL_${suffix}=https://${ref}.supabase.co"
    echo "SUPABASE_PUBLISHABLE_KEY_${suffix}=${pub}"
    echo "SUPABASE_DB_URL_${suffix}=postgresql://postgres:${pw}@db.${ref}.supabase.co:5432/postgres"
  } >> "$KEYS_FILE"
}

umask 077
: > "$KEYS_FILE"

if [ "$MODE" = "projects" ]; then
  prod_out="$(create_project "${SLUG}-prod")" || exit 1
  prod_ref="${prod_out%% *}"; prod_pw="${prod_out#* }"
  write_env_block PROD "$prod_ref" "$prod_pw" || exit 1

  staging_out="$(create_project "${SLUG}-staging")" || exit 1
  staging_ref="${staging_out%% *}"; staging_pw="${staging_out#* }"
  write_env_block STAGING "$staging_ref" "$staging_pw" || exit 1

  echo "supabase: setup complete, mode=projects (keys written to keys file)"
fi

if [ "$MODE" = "branch" ]; then
  prod_out="$(create_project "${SLUG}")" || exit 1
  prod_ref="${prod_out%% *}"; prod_pw="${prod_out#* }"
  write_env_block PROD "$prod_ref" "$prod_pw" || exit 1

  if branch_out="$(supabase branches create dev --persistent --project-ref "$prod_ref" -o json 2>&1)"; then
    branch_ref="$(printf '%s' "$branch_out" | jq -r '.ref // empty' 2>/dev/null)"
  else
    branch_ref=""
  fi

  if [ -n "$branch_ref" ]; then
    # A persistent branch is its own project-like entity: it has its own
    # ref and API keys, but shares the parent project's DB password.
    write_env_block STAGING "$branch_ref" "$prod_pw" || exit 1
    echo "SUPABASE_STAGING_PROVISIONED=yes" >> "$KEYS_FILE"
    echo "supabase: setup complete, mode=branch (staging is a persistent branch of $prod_ref)"
  else
    echo "SUPABASE_STAGING_PROVISIONED=no" >> "$KEYS_FILE"
    echo "supabase: prod project ready ($prod_ref); persistent branch creation did not succeed (best-effort): $branch_out" >&2
    echo "supabase: connect this repo in Supabase → Settings → Integrations → GitHub, then create a persistent 'dev' branch from the dashboard (or re-run: supabase branches create dev --persistent --project-ref $prod_ref)."
  fi
fi
