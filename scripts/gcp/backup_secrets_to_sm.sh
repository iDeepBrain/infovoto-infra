#!/usr/bin/env bash
#
# backup_secrets_to_sm.sh — Back up local .env.secrets into GCP Secret Manager.
#
# WHY: several secrets live ONLY in the local root .env.secrets (gitignored, never
# pushed). This script copies them into Secret Manager so the project can be fully
# recreated/re-activated after the local folder is deleted.
#
# PRIVACY: this script only READS your local .env.secrets and PUSHES values to your
# own Secret Manager. It prints only secret NAMES + CREATED/UPDATED — never values.
# Run it yourself; no secret value is ever exposed to anyone else.
#
# USAGE (from the project root, where .env.secrets lives):
#   bash infovoto-infra/scripts/gcp/backup_secrets_to_sm.sh [path/to/.env.secrets]
#
set -euo pipefail

ENV_FILE="${1:-.env.secrets}"
PROJECT="proyectosia-423918"

# Keys that exist only locally and must be backed up (audited 2026-07-17).
GAP_KEYS=(
  ADMIN_TOKEN API_KEY_ADMIN API_KEY_GRADIO
  AZURE_DOCUMENT_INTELLIGENCE_ENDPOINT AZURE_DOCUMENT_INTELLIGENCE_KEY
  DATABASE_URL_SUPABASE REDIS_URL_PROD
  SUPABASE_ANON_KEY SUPABASE_DB_HOST SUPABASE_DB_PASSWORD
  SUPABASE_PROJECT_ID SUPABASE_SERVICE_KEY SUPABASE_URL
  WHATSAPP_ACCESS_TOKEN WHATSAPP_APP_SECRET WHATSAPP_PHONE_NUMBER_ID WHATSAPP_VERIFY_TOKEN
  OPENAI_API_KEY
)

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Pass the path as the first argument." >&2
  exit 1
fi

echo "Backing up ${#GAP_KEYS[@]} keys from $ENV_FILE to Secret Manager (project $PROJECT)"
echo "Only names are printed below — never values."
echo

for key in "${GAP_KEYS[@]}"; do
  # Extract the value for this key (strip optional surrounding quotes). Never printed.
  val="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ENV_FILE" | head -1 | sed -E "s/^[^=]*=//; s/^[\"']//; s/[\"'][[:space:]]*$//")"
  if [[ -z "${val}" ]]; then
    echo "SKIP    $key  (not present in $ENV_FILE)"
    continue
  fi
  if gcloud secrets describe "$key" --project="$PROJECT" >/dev/null 2>&1; then
    printf '%s' "$val" | gcloud secrets versions add "$key" --data-file=- --project="$PROJECT" >/dev/null
    echo "UPDATED $key"
  else
    printf '%s' "$val" | gcloud secrets create "$key" --data-file=- \
      --replication-policy="automatic" --project="$PROJECT" >/dev/null
    echo "CREATED $key"
  fi
done

echo
echo "Done. Verify with:  gcloud secrets list --project=$PROJECT"
