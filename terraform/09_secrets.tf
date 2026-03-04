# ─────────────────────────────────────────────────────────────────────────────
# Secrets — AWS Secrets Manager
#
# WHY NOT data sources in this file?
# Terraform initialises ALL providers before it reads any data sources, which
# creates a circular dependency: the dbtcloud provider needs the token to init,
# but reading the token from Secrets Manager requires a data source, which
# requires the provider to already be up.  The standard solution is to inject
# secrets as TF_VAR_* environment variables BEFORE calling terraform.
# scripts/tf_with_secrets.sh does exactly that — it fetches the two secrets
# below, exports TF_VAR_dbt_token / TF_VAR_snowflake_user /
# TF_VAR_snowflake_private_key, then execs `terraform -chdir=terraform "$@"`.
#
# ─── Secret layout ────────────────────────────────────────────────────────────
#
#  Secret path                           Keys
#  ──────────────────────────────────    ──────────────────────────────────────
#  sportsco-project-migration/dbtcloud        token
#  sportsco-project-migration/snowflake-svc       user, private_key
#
# ─── One-time setup (run once per environment) ────────────────────────────────
#
#  aws secretsmanager create-secret \
#    --name "sportsco-project-migration/dbtcloud" \
#    --description "dbt Cloud API token for SportsCo project migration" \
#    --secret-string '{"token":"dbtc_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'
#
#  Generate an RSA keypair for the Snowflake service account (unencrypted):
#    openssl genrsa 4096 | openssl pkcs8 -topk8 -nocrypt -out snowflake_rsa.p8
#    openssl rsa -in snowflake_rsa.p8 -pubout -out snowflake_rsa.pub
#  Assign the public key to the user in Snowflake:
#    ALTER USER DBT_SVC_USER SET RSA_PUBLIC_KEY='<contents of snowflake_rsa.pub, header/footer stripped>';
#  Store the private key (the full PEM including header/footer):
#  aws secretsmanager create-secret \
#    --name "sportsco-project-migration/snowflake-svc" \
#    --description "Snowflake service account keypair for dbt Cloud" \
#    --secret-string "{\"user\":\"DBT_SVC_USER\",\"private_key\":\"$(cat snowflake_rsa.p8)\"}"
#  Then delete the local key files:
#    rm snowflake_rsa.p8 snowflake_rsa.pub
#
# ─── Rotating the keypair ─────────────────────────────────────────────────────
#
#  Regenerate keys, reassign the public key in Snowflake, then:
#  aws secretsmanager put-secret-value \
#    --secret-id "sportsco-project-migration/snowflake-svc" \
#    --secret-string "{\"user\":\"DBT_SVC_USER\",\"private_key\":\"$(cat new_rsa.p8)\"}"
#
#  aws secretsmanager put-secret-value \
#    --secret-id "sportsco-project-migration/dbtcloud" \
#    --secret-string '{"token":"dbtc_new_token_here"}'
#
#  Then re-run:  make apply    (tf_with_secrets.sh fetches the new value)
#
# ─── IAM policy required for the role that runs terraform ─────────────────────
#
#  {
#    "Version": "2012-10-17",
#    "Statement": [{
#      "Effect": "Allow",
#      "Action": ["secretsmanager:GetSecretValue"],
#      "Resource": [
#        "arn:aws:secretsmanager:<region>:<account>:secret:sportsco-project-migration/*"
#      ]
#    }]
#  }
#
# ─────────────────────────────────────────────────────────────────────────────

# Optional: path prefix variable so the same config works across environments.
# Override in terraform.tfvars if you prefix secrets differently (e.g. prod/).
variable "secrets_prefix" {
  description = "AWS Secrets Manager path prefix for this project's secrets"
  type        = string
  default     = "sportsco-project-migration"
}
