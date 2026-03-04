#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# tf_with_secrets.sh
#
# Wrapper around `terraform` that fetches credentials from AWS Secrets Manager
# and injects them as TF_VAR_* environment variables before calling terraform.
#
# This sidesteps Terraform's chicken-and-egg problem: providers are initialised
# before data sources are read, so the dbtcloud provider token cannot come from
# an aws_secretsmanager_secret_version data source.  Injecting via TF_VAR_*
# is the idiomatic solution — the variable block in variables.tf still defines
# type/sensitivity; the value is never written to disk.
#
# Usage (mirrors terraform args exactly):
#   bash scripts/tf_with_secrets.sh plan
#   bash scripts/tf_with_secrets.sh apply
#   bash scripts/tf_with_secrets.sh apply -target=dbtcloud_group.val_archived_readonly
#
# Required:
#   AWS credentials in the environment (IAM role, AWS_PROFILE, aws-vault, etc.)
#   aws CLI installed
#   python3 in PATH (used for JSON parsing; swap for jq if preferred)
#
# Optional env overrides:
#   SECRETS_PREFIX          default: sportsco-project-migration
#   AWS_DEFAULT_REGION      default: us-east-1
#   TF_DIR                  default: terraform
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SECRETS_PREFIX="${SECRETS_PREFIX:-sportsco-project-migration}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
TF_DIR="${TF_DIR:-terraform}"

# ── Helper: fetch a Secrets Manager secret as a JSON string ──────────────────
get_secret() {
    local secret_id="$1"
    aws secretsmanager get-secret-value \
        --secret-id    "$secret_id" \
        --region       "$REGION" \
        --query        SecretString \
        --output       text
}

# ── Helper: extract a key from a JSON string via Python ──────────────────────
json_key() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | python3 -c "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    # PEM keys stored via \$(cat file) have literal newlines that break JSON.
    # Escape them so json.loads can parse the string.
    d = json.loads(raw.replace(chr(10), r'\n'))
print(d['$key'])
"
}

echo "Fetching secrets from AWS Secrets Manager (prefix: $SECRETS_PREFIX) …"

# ── dbt Cloud token ───────────────────────────────────────────────────────────
DBT_JSON=$(get_secret "${SECRETS_PREFIX}/dbtcloud")
export TF_VAR_dbt_token
TF_VAR_dbt_token=$(json_key "$DBT_JSON" token)

# ── Snowflake service account ─────────────────────────────────────────────────
SNOW_JSON=$(get_secret "${SECRETS_PREFIX}/snowflake-svc")
export TF_VAR_snowflake_user
TF_VAR_snowflake_user=$(json_key "$SNOW_JSON" user)
export TF_VAR_snowflake_private_key
TF_VAR_snowflake_private_key=$(json_key "$SNOW_JSON" private_key)

echo "Secrets loaded. Running: terraform -chdir=$TF_DIR $*"
echo ""

exec terraform -chdir="$TF_DIR" "$@"
