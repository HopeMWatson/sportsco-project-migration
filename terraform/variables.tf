# ─── dbt Cloud ────────────────────────────────────────────────────────────────

variable "dbt_account_id" {
  description = "dbt Cloud account ID (found in the URL: cloud.getdbt.com/accounts/<id>/)"
  type        = number
}

variable "dbt_token" {
  description = "dbt Cloud API token. Do NOT set in terraform.tfvars — injected at runtime as TF_VAR_dbt_token by scripts/tf_with_secrets.sh from AWS Secrets Manager (sportsco-project-migration/dbtcloud → token)"
  type        = string
  sensitive   = true
}

variable "dbt_host_url" {
  description = "dbt Cloud API base URL"
  type        = string
  default     = "https://cloud.getdbt.com/api"
}

# ─── AWS ──────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for the S3 job-run backup bucket"
  type        = string
  default     = "us-east-1"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket that will store job run history from the val project"
  type        = string
}

# ─── Snowflake ────────────────────────────────────────────────────────────────

variable "snowflake_account" {
  description = "Snowflake account identifier (e.g. xy12345.us-east-1)"
  type        = string
}

variable "snowflake_database" {
  description = "Target Snowflake database"
  type        = string
  default     = "SPORTSCO_ANALYTICS"
}

variable "snowflake_warehouse" {
  description = "Snowflake virtual warehouse"
  type        = string
  default     = "TRANSFORMING_WH"
}

variable "snowflake_role" {
  description = "Snowflake role used by dbt"
  type        = string
  default     = "TRANSFORMER"
}

variable "snowflake_user" {
  description = "Snowflake service account username. Do NOT set in terraform.tfvars — injected at runtime as TF_VAR_snowflake_user by scripts/tf_with_secrets.sh from AWS Secrets Manager (sportsco-project-migration/snowflake-svc → user)"
  type        = string
  sensitive   = true
}

variable "snowflake_private_key" {
  description = "Snowflake service account RSA private key (PEM, unencrypted). Do NOT set in terraform.tfvars — injected at runtime as TF_VAR_snowflake_private_key by scripts/tf_with_secrets.sh from AWS Secrets Manager (sportsco-project-migration/snowflake-svc → private_key)"
  type        = string
  sensitive   = true
}

# ─── GitHub ───────────────────────────────────────────────────────────────────

variable "github_repo_url" {
  description = "SSH or HTTPS URL of the dbt project GitHub repository"
  type        = string
}

variable "github_installation_id" {
  description = "GitHub App installation ID configured in dbt Cloud"
  type        = number
}

# ─── Git branches ─────────────────────────────────────────────────────────────

variable "val_branch" {
  description = "Git branch for the val (validation) environment"
  type        = string
  default     = "val"
}

variable "prod_branch" {
  description = "Git branch for the prod environment"
  type        = string
  default     = "main"
}
