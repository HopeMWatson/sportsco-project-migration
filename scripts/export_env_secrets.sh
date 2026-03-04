#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# export_env_secrets.sh
#
# Prints `export KEY=VALUE` lines for all secrets and terraform outputs needed
# by the Python scripts and Makefile targets (backup-runs, trigger-migrated,
# terraform-image, etc.).
#
# Usage — source into your current shell:
#   source <(bash scripts/export_env_secrets.sh)
#
# Or write to .env and use the Makefile's -include .env:
#   bash scripts/export_env_secrets.sh > .env
#   # then: make backup-runs
#
# What this exports:
#   DBT_TOKEN               from Secrets Manager
#   DBT_ACCOUNT_ID          from terraform output
#   DBT_VAL_PROJECT_ID      from terraform output
#   DBT_VAL_ENV_ID          from terraform output
#   DBT_PROD_PROJECT_ID     from terraform output
#   DBT_PROD_VAL_ENV_ID     from terraform output
#   S3_BUCKET               from terraform output
#   DBT_HOST                hardcoded default (override if needed)
#
# Required:
#   aws CLI + valid IAM credentials
#   terraform state populated (i.e. Phase 1 `make apply` already done)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SECRETS_PREFIX="${SECRETS_PREFIX:-sportsco-project-migration}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TF_DIR="${TF_DIR:-terraform}"
DBT_HOST="${DBT_HOST:-https://cloud.getdbt.com/api}"

# ── Helper: extract a key from a JSON string ─────────────────────────────────
json_key() {
    echo "$1" | python3 -c "import sys, json; print(json.load(sys.stdin)['$2'])"
}

# ── Helper: extract a value from cached terraform JSON outputs ────────────────
# Uses -json (not -raw) so terraform writes warnings to stderr, not stdout.
# Call _tf_load_outputs once, then use tf_output for individual keys.
_tf_load_outputs() {
    terraform -chdir="$TF_DIR" output -json 2>/dev/null || echo "{}"
}

tf_output() {
    local key="$1"
    echo "$_TF_OUTPUTS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
v = d.get('$key', {})
print(v.get('value', '') if isinstance(v, dict) else '')
" 2>/dev/null || echo ""
}

# ── 1. Secrets from Secrets Manager ──────────────────────────────────────────
DBT_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "${SECRETS_PREFIX}/dbtcloud" \
    --region    "$REGION" \
    --query     SecretString \
    --output    text)

echo "export DBT_TOKEN=$(json_key "$DBT_JSON" token)"
echo "export DBT_HOST=$DBT_HOST"

# ── 2. Project / environment IDs from terraform outputs ──────────────────────
# These are only available after Phase 1 `make apply` has run.
# If terraform hasn't been applied yet, these will be empty strings.

_TF_OUTPUTS=$(_tf_load_outputs)
VAL_PROJECT_ID=$(tf_output "val_project_id")
VAL_ENV_ID=$(tf_output "val_deployment_environment_id")
PROD_PROJECT_ID=$(tf_output "prod_project_id")
PROD_VAL_ENV_ID=$(tf_output "prod_val_environment_id")
S3_BUCKET=$(tf_output "job_run_backup_bucket")

# We need account_id for scripts — read it from the TF var (non-sensitive, in tfvars)
DBT_ACCOUNT_ID=$(terraform -chdir="$TF_DIR" output -json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('')" 2>/dev/null || true)
# Fall back to reading from terraform.tfvars directly (account_id is not sensitive)
if [ -f "$TF_DIR/terraform.tfvars" ]; then
    DBT_ACCOUNT_ID=$(grep 'dbt_account_id' "$TF_DIR/terraform.tfvars" \
        | head -1 | sed 's/.*=\s*//' | sed 's/#.*//' | tr -d ' "' || echo "")
fi

[ -n "$DBT_ACCOUNT_ID"  ] && echo "export DBT_ACCOUNT_ID=$DBT_ACCOUNT_ID"       || true
[ -n "$VAL_PROJECT_ID"  ] && echo "export DBT_VAL_PROJECT_ID=$VAL_PROJECT_ID"   || true
[ -n "$VAL_ENV_ID"      ] && echo "export DBT_VAL_ENV_ID=$VAL_ENV_ID"           || true
[ -n "$PROD_PROJECT_ID" ] && echo "export DBT_PROD_PROJECT_ID=$PROD_PROJECT_ID" || true
[ -n "$PROD_VAL_ENV_ID" ] && echo "export DBT_PROD_VAL_ENV_ID=$PROD_VAL_ENV_ID" || true
[ -n "$S3_BUCKET"       ] && echo "export S3_BUCKET=$S3_BUCKET"                 || true
